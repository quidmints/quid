// step_executors.go — Concrete StepExecutor implementations
//
// Registers all built-in executors in init(). Each executor implements
// the StepExecutor interface declared in execution_plan.go.
//
// Model dispatch (dispatchToModel, findRouteURI) lives in model_dispatch.go.
// Adaptation blobs pre-loaded from 0G Storage by oracle_main.go are accessed
// via Session.AdaptationBlobs[devicePubkeyHex].
//
// SHUFFLER NOTE:
//   Shuffler is not a registered step type — it ran as a privacy-preserving
//   composition layer in earlier versions but has been subsumed into the
//   CLASSIFY step. localShufflerCompose() remains available as a helper
//   callable by any executor or by the RunShufflerComposition() bridge.

package main

import (
	"fmt"
	"sort"
	"strings"
)

// ─────────────────────────────────────────────────────────────────────────────
// REGISTRATION
// ─────────────────────────────────────────────────────────────────────────────

func init() {
	defaultRegistry.Register(&FingerprintExecutor{})
	defaultRegistry.Register(&ClassifyExecutor{})
	defaultRegistry.Register(&TranscribeExecutor{})
	defaultRegistry.Register(&EmbedExecutor{})
	defaultRegistry.Register(&EvaluateExecutor{})
	defaultRegistry.Register(&ResolveExecutor{})
}

// ─────────────────────────────────────────────────────────────────────────────
// FINGERPRINT EXECUTOR
// Shazam-style landmark matching: verifies audio provenance against a reference.
// ─────────────────────────────────────────────────────────────────────────────

type FingerprintExecutor struct{}

func (e *FingerprintExecutor) Type() StepType { return StepFingerprint }

func (e *FingerprintExecutor) Execute(step PipelineStep, inputs map[string]*StepResult, s *Session) (*StepResult, error) {
	r := &StepResult{StepName: step.Name, StepType: StepFingerprint}
	if s.Summary == nil || len(s.Summary.Verified) == 0 {
		return nil, fmt.Errorf("no verified evidence for fingerprint step")
	}
	threshold := step.Params.MatchThreshold
	if threshold == 0 {
		threshold = 7000
	}
	uri := step.Params.ProviderURI
	req := ModelRequest{
		StepType:  StepFingerprint,
		Params:    step.Params,
		InputData: s.Summary,
		MarketKey: s.MarketKey,
	}
	resp, err := dispatchToModel(uri, req)
	if err != nil {
		return nil, fmt.Errorf("fingerprint dispatch: %w", err)
	}
	if !resp.Success {
		return nil, fmt.Errorf("fingerprint model: %s", resp.Error)
	}
	r.FingerprintScore = resp.MatchScore
	r.FingerprintMatch = resp.MatchScore >= threshold
	r.ReferenceID = resp.ReferenceID
	return r, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// CLASSIFY EXECUTOR
// Aggregates SE-signed tags from device evidence.
// No model dispatch needed — tags are already in s.Summary after
// EvidenceVerifyPostprocessor runs.
// ─────────────────────────────────────────────────────────────────────────────

type ClassifyExecutor struct{}

func (e *ClassifyExecutor) Type() StepType { return StepClassify }

func (e *ClassifyExecutor) Execute(step PipelineStep, inputs map[string]*StepResult, s *Session) (*StepResult, error) {
	r := &StepResult{StepName: step.Name, StepType: StepClassify}
	if s.Summary == nil {
		return nil, fmt.Errorf("no evidence summary for classify step")
	}
	minConf := step.Params.MinConfBps
	if minConf == 0 {
		minConf = 5000
	}
	required := make(map[string]bool)
	for _, t := range step.Params.RequiredTags {
		required[t] = true
	}
	for _, ve := range s.Summary.Verified {
		for _, tag := range ve.Tags {
			if (len(required) == 0 || required[tag.Name]) &&
				int64(tag.Confidence) >= minConf {
				r.ClassifiedTags = append(r.ClassifiedTags, tag)
			}
		}
	}
	return r, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// TRANSCRIBE EXECUTOR
// Speech-to-text via Whisper (model_class=1).
// Skipped automatically if no Speech tag is present in evidence.
// ─────────────────────────────────────────────────────────────────────────────

type TranscribeExecutor struct{}

func (e *TranscribeExecutor) Type() StepType { return StepTranscribe }

func (e *TranscribeExecutor) Execute(step PipelineStep, inputs map[string]*StepResult, s *Session) (*StepResult, error) {
	r := &StepResult{StepName: step.Name, StepType: StepTranscribe}
	if s.Summary == nil {
		return nil, fmt.Errorf("no evidence summary")
	}
	// Gate: speech must be present in at least one verified submission.
	speechPresent := false
	for _, ve := range s.Summary.Verified {
		for _, tag := range ve.Tags {
			if tag.Name == "Speech" || tag.Name == "SpeechMultiple" {
				speechPresent = true
				break
			}
		}
		if speechPresent {
			break
		}
	}
	r.SpeechPresent = speechPresent
	if !speechPresent {
		r.Skipped = true
		r.Error = "no Speech tags above threshold"
		return r, nil
	}
	// model_class=1 (TRANSCRIBER) — requires 0g: route in PipelineRoutes.
	uri := findRouteURI(1, s.Evidence, "")
	req := ModelRequest{
		StepType:  StepTranscribe,
		Params:    step.Params,
		InputData: s.Summary,
		MarketKey: s.MarketKey,
	}
	resp, err := dispatchToModel(uri, req)
	if err != nil {
		return nil, fmt.Errorf("transcribe dispatch: %w", err)
	}
	if !resp.Success {
		return nil, fmt.Errorf("transcribe model: %s", resp.Error)
	}
	r.Transcript = resp.Transcript
	r.KeywordMatches = resp.KeywordMatches
	return r, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// EMBED EXECUTOR
// Semantic similarity between transcript and reference text (model_class=2).
// Skipped if no transcript from the input step.
// ─────────────────────────────────────────────────────────────────────────────

type EmbedExecutor struct{}

func (e *EmbedExecutor) Type() StepType { return StepEmbed }

func (e *EmbedExecutor) Execute(step PipelineStep, inputs map[string]*StepResult, s *Session) (*StepResult, error) {
	r := &StepResult{StepName: step.Name, StepType: StepEmbed}
	var transcript string
	if step.InputStep != "" {
		if prior, ok := inputs[step.InputStep]; ok && !prior.Skipped {
			transcript = prior.Transcript
		}
	}
	if transcript == "" {
		r.Skipped = true
		r.Error = "no transcript from input step"
		return r, nil
	}
	minSim := step.Params.SimilarityMin
	if minSim == 0 {
		minSim = 6000
	}
	// model_class=2 (EMBEDDER) — requires 0g: route in PipelineRoutes.
	uri := findRouteURI(2, s.Evidence, "")
	req := ModelRequest{
		StepType:  StepEmbed,
		Params:    step.Params,
		InputData: map[string]string{"transcript": transcript, "reference": step.Params.ReferenceText},
		MarketKey: s.MarketKey,
	}
	resp, err := dispatchToModel(uri, req)
	if err != nil {
		return nil, fmt.Errorf("embed dispatch: %w", err)
	}
	r.SimilarityScore = resp.SimilarityScore
	r.SimilarityMatch = resp.SimilarityScore >= minSim
	return r, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// EVALUATE EXECUTOR
// Composite quality score across dimensions from prior steps.
// Pure Go aggregation — no model dispatch.
// scoreFromResult() is defined in execution_plan.go (shared with gate eval).
// ─────────────────────────────────────────────────────────────────────────────

type EvaluateExecutor struct{}

func (e *EvaluateExecutor) Type() StepType { return StepEvaluate }

func (e *EvaluateExecutor) Execute(step PipelineStep, inputs map[string]*StepResult, s *Session) (*StepResult, error) {
	r := &StepResult{StepName: step.Name, StepType: StepEvaluate, DimScores: make(map[string]int64)}
	var totalWeight, weightedScore float64
	allPassed := true
	for _, dim := range step.Params.Dimensions {
		w := dim.Weight
		if w == 0 {
			w = 1.0
		}
		totalWeight += w
		var score int64
		if prior, ok := inputs[dim.FromStep]; ok && !prior.Skipped {
			score = scoreFromResult(prior, dim.FieldName)
		}
		r.DimScores[dim.Name] = score
		if score < dim.MinScore {
			allPassed = false
		}
		weightedScore += w * float64(score)
	}
	if totalWeight > 0 {
		r.QualityScore = int64(weightedScore / totalWeight)
	}
	r.QualityPassed = allPassed
	return r, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// RESOLVE EXECUTOR
// Terminal step — injects plan results into session for resolution postprocessors.
// Actual resolution happens in DeterministicResolvePostprocessor or the LLM path.
// ─────────────────────────────────────────────────────────────────────────────

type ResolveExecutor struct{}

func (e *ResolveExecutor) Type() StepType { return StepResolve }

func (e *ResolveExecutor) Execute(step PipelineStep, inputs map[string]*StepResult, s *Session) (*StepResult, error) {
	r := &StepResult{StepName: step.Name, StepType: StepResolve}
	s.PlanResults = inputs
	// If resolution was already set (e.g. plan short-circuited), propagate.
	if s.Resolution != nil {
		r.OutcomeIndex = s.Resolution.OutcomeIndex
		r.Confidence = s.Resolution.Confidence
	}
	return r, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// SHUFFLER COMPOSITION
// Privacy-preserving tag aggregation across N devices. Not a registered step.
// mode: "union" (any device), "intersection" (all devices), "weighted" (default).
// ─────────────────────────────────────────────────────────────────────────────

func localShufflerCompose(summary *EvidenceSummary, mode string) ([]ComposedTag, error) {
	if summary == nil || len(summary.Verified) == 0 {
		return nil, fmt.Errorf("no verified evidence")
	}
	if mode == "" {
		mode = "weighted"
	}

	type tagAccum struct {
		totalConf   int64
		deviceCount int
		slotCount   int
	}
	accum := make(map[string]*tagAccum)
	totalDevices := len(summary.Verified)

	for _, ve := range summary.Verified {
		seen := make(map[string]bool)
		for _, tag := range ve.Tags {
			if seen[tag.Name] {
				continue
			}
			seen[tag.Name] = true
			a := accum[tag.Name]
			if a == nil {
				a = &tagAccum{}
				accum[tag.Name] = a
			}
			a.totalConf += int64(tag.Confidence)
			a.deviceCount++
			a.slotCount += int(tag.SlotCount)
		}
	}

	var result []ComposedTag
	for name, a := range accum {
		var present bool
		switch mode {
		case "union":
			present = a.deviceCount > 0
		case "intersection":
			present = a.deviceCount == totalDevices
		default: // weighted
			present = a.totalConf/int64(a.deviceCount) >= 5000
		}
		meanConf := int64(0)
		if a.deviceCount > 0 {
			meanConf = a.totalConf / int64(a.deviceCount)
		}
		result = append(result, ComposedTag{
			Name:        name,
			MeanConfBps: meanConf,
			DeviceCount: a.deviceCount,
			Present:     present,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].MeanConfBps > result[j].MeanConfBps
	})
	return result, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// RUN HELPERS — bridge for callers that don't use the executor registry directly
// ─────────────────────────────────────────────────────────────────────────────

func RunFingerprintMatch(referenceHash string, summary *EvidenceSummary) (int64, string, error) {
	if summary == nil {
		return 0, "", fmt.Errorf("no evidence summary")
	}
	req := ModelRequest{
		StepType:  StepFingerprint,
		Params:    StepParams{ReferenceHash: referenceHash},
		InputData: summary,
	}
	resp, err := dispatchToModel("", req)
	if err != nil {
		return 0, "", err
	}
	return resp.MatchScore, resp.ReferenceID, nil
}

func RunShufflerComposition(summary *EvidenceSummary, mode string) ([]ComposedTag, error) {
	return localShufflerCompose(summary, mode)
}

func RunTranscription(summary *EvidenceSummary, language string, keywords []string) (string, []string, error) {
	req := ModelRequest{
		StepType:  StepTranscribe,
		Params:    StepParams{Language: language, Keywords: keywords},
		InputData: summary,
	}
	resp, err := dispatchToModel("", req)
	if err != nil {
		return "", nil, err
	}
	return resp.Transcript, resp.KeywordMatches, nil
}

func RunEmbeddingSimilarity(transcript, referenceText string) (int64, error) {
	req := ModelRequest{
		StepType:  StepEmbed,
		InputData: map[string]string{"transcript": transcript, "reference": referenceText},
	}
	resp, err := dispatchToModel("", req)
	if err != nil {
		return 0, err
	}
	return resp.SimilarityScore, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// FORMAT PLAN RESULTS FOR LLM PROMPT
// Produces the PIPELINE STEP RESULTS block injected into resolve.go's prompt
// when s.PlanResults is populated by the ResolveExecutor.
// ─────────────────────────────────────────────────────────────────────────────

func FormatPlanResultsForPrompt(planResults map[string]*StepResult) string {
	if len(planResults) == 0 {
		return ""
	}
	var sb strings.Builder
	sb.WriteString("PIPELINE STEP RESULTS:\n")
	for name, r := range planResults {
		if r.Skipped {
			sb.WriteString(fmt.Sprintf("  [%s] SKIPPED: %s\n", name, r.Error))
			continue
		}
		switch r.StepType {
		case StepFingerprint:
			sb.WriteString(fmt.Sprintf("  [%s] fingerprint_score=%d match=%v ref=%s\n",
				name, r.FingerprintScore, r.FingerprintMatch, r.ReferenceID))
		case StepClassify:
			sb.WriteString(fmt.Sprintf("  [%s] %d tags classified\n",
				name, len(r.ClassifiedTags)))
			for _, t := range r.ClassifiedTags {
				sb.WriteString(fmt.Sprintf("    %s: %d bps\n", t.Name, t.Confidence))
			}
		case StepTranscribe:
			if r.Transcript != "" {
				sb.WriteString(fmt.Sprintf("  [%s] transcript: %q\n", name, r.Transcript))
			}
			if len(r.KeywordMatches) > 0 {
				sb.WriteString(fmt.Sprintf("    keywords matched: %v\n", r.KeywordMatches))
			}
		case StepEmbed:
			sb.WriteString(fmt.Sprintf("  [%s] similarity_score=%d match=%v\n",
				name, r.SimilarityScore, r.SimilarityMatch))
		case StepEvaluate:
			sb.WriteString(fmt.Sprintf("  [%s] quality_score=%d passed=%v\n",
				name, r.QualityScore, r.QualityPassed))
			for dim, score := range r.DimScores {
				sb.WriteString(fmt.Sprintf("    %s: %d\n", dim, score))
			}
		}
	}
	return sb.String()
}
