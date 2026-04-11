// execution_plan.go — Market-Specific Oracle Execution Plan
//
// STATE.RS HAS:
//   resolution_mode  — where to execute (deterministic/TEE/Claude/auto)
//   pipeline_routes  — model registry: which model handles which tags
//
// THIS FILE ADDS:
//   ExecutionPlan    — ordered sequence of PipelineSteps for one market
//   PipelineStep     — typed unit of work with input source + output contract
//   StepGate         — condition that must pass before a step runs
//   StepResult       — typed output carried forward through the plan
//   StepExecutor     — interface implemented by each step type
//   ExecutorRegistry — maps StepType → StepExecutor; populated by init()
//
// HOW IT WORKS:
//   1. Market creator encodes ExecutionPlan as JSON in EvidenceRequirements
//   2. Oracle reads MarketEvidence, calls ParseExecutionPlan()
//   3. ExecutionPlanner.Run() dispatches each step through the executor registry
//   4. Final RESOLVE step feeds into the resolution postprocessors
//
// STEP TYPES:
//   FINGERPRINT  — audio provenance verification against reference hash
//   CLASSIFY     — aggregate SE-signed tags from device evidence
//   TRANSCRIBE   — speech-to-text (model_class=1, requires Speech tag)
//   EMBED        — semantic similarity (model_class=2, requires transcript)
//   EVALUATE     — composite quality scoring across prior steps
//   CUSTOM       — market-defined, dispatched by provider_uri
//   RESOLVE      — terminal step; injects plan results for resolution

package main

import (
	"encoding/json"
	"fmt"
	"log"
)

// ─────────────────────────────────────────────────────────────────────────────
// STEP EXECUTOR INTERFACE
//
// Every step type implements this. Registered in the executor registry.
// Concrete implementations live in step_executors.go.
// ─────────────────────────────────────────────────────────────────────────────

type StepExecutor interface {
	// Type returns the StepType this executor handles.
	Type() StepType
	// Execute runs the step and returns its result.
	// inputs: outputs from prior steps, keyed by step name.
	// session: read-only access to market data and evidence summary.
	Execute(step PipelineStep, inputs map[string]*StepResult, s *Session) (*StepResult, error)
}

// ExecutorRegistry maps StepType → StepExecutor.
// Default executors registered in step_executors.go init().
type ExecutorRegistry struct {
	executors map[StepType]StepExecutor
}

// defaultRegistry is the package-level registry used by all ExecutionPlanners.
var defaultRegistry = &ExecutorRegistry{
	executors: make(map[StepType]StepExecutor),
}

func (r *ExecutorRegistry) Register(e StepExecutor) {
	r.executors[e.Type()] = e
}

func (r *ExecutorRegistry) Get(t StepType) (StepExecutor, error) {
	e, ok := r.executors[t]
	if !ok {
		return nil, fmt.Errorf("no executor for step type %s", t)
	}
	return e, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP TYPES
// ─────────────────────────────────────────────────────────────────────────────

type StepType string

const (
	StepFingerprint StepType = "FINGERPRINT" // verify audio provenance against reference
	StepClassify    StepType = "CLASSIFY"    // aggregate tags from device evidence (model_class=0)
	StepTranscribe  StepType = "TRANSCRIBE"  // speech-to-text (model_class=1)
	StepEmbed       StepType = "EMBED"       // semantic similarity (model_class=2)
	StepEvaluate    StepType = "EVALUATE"    // composite quality scoring across prior steps
	StepCustom      StepType = "CUSTOM"      // market-defined step dispatched by provider_uri
	StepResolve     StepType = "RESOLVE"     // terminal step; injects plan results for resolution
)

// ─────────────────────────────────────────────────────────────────────────────
// INPUT SOURCE — where a step reads its primary input from
// ─────────────────────────────────────────────────────────────────────────────

type InputSource string

const (
	SourceDeviceEvidence InputSource = "device_evidence"
	SourceStep           InputSource = "step"
	SourceMarket         InputSource = "market"
	SourcePrivacy        InputSource = "privacy"
)

// ─────────────────────────────────────────────────────────────────────────────
// GATE — condition that must pass before a step executes
// ─────────────────────────────────────────────────────────────────────────────

type GateType string

const (
	GateMinScore    GateType = "MIN_SCORE"    // prior step score >= threshold
	GateTagPresent  GateType = "TAG_PRESENT"  // named tag in evidence above min_bps
	GateMinDevices  GateType = "MIN_DEVICES"  // verified device count >= threshold
	GateFieldTrue   GateType = "FIELD_TRUE"   // named bool field in prior step output
	GateMinSessions GateType = "MIN_SESSIONS" // evidence session count >= threshold
)

type StepGate struct {
	Type      GateType `json:"type"`
	Reference string   `json:"reference,omitempty"`  // tag name / field name / score reference
	FromStep  string   `json:"from_step,omitempty"`  // which step's output to read
	Threshold int64    `json:"threshold"`             // numeric threshold (bps or count)
	AbortOnFail bool   `json:"abort_on_fail"`         // true = abort plan; false = skip step
}

// ─────────────────────────────────────────────────────────────────────────────
// PIPELINE STEP
// ─────────────────────────────────────────────────────────────────────────────

type PipelineStep struct {
	Name        string      `json:"name"`
	Type        StepType    `json:"type"`
	InputSource InputSource `json:"input_source"`
	InputStep   string      `json:"input_step,omitempty"`
	Gate        *StepGate   `json:"gate,omitempty"`
	Params      StepParams  `json:"params"`
}

// StepParams holds per-step-type configuration.
// Only fields relevant to the step's type need to be set.
type StepParams struct {
	// FINGERPRINT
	ReferenceHash  string `json:"reference_hash,omitempty"`
	MatchThreshold int64  `json:"match_threshold,omitempty"` // bps; default 7000

	// CLASSIFY
	MinConfBps   int64    `json:"min_conf_bps,omitempty"`
	RequiredTags []string `json:"required_tags,omitempty"` // filter to these tags only

	// TRANSCRIBE
	Language string   `json:"language,omitempty"` // ISO 639-1; empty = auto-detect
	Keywords []string `json:"keywords,omitempty"` // keyword spotting list

	// EMBED
	ReferenceText string `json:"reference_text,omitempty"`
	SimilarityMin int64  `json:"similarity_min,omitempty"` // bps; default 6000

	// EVALUATE
	Dimensions []EvalDimension `json:"dimensions,omitempty"`

	// CUSTOM — any step dispatched by provider_uri
	ProviderURI string `json:"provider_uri,omitempty"`
	ArgsJSON    string `json:"args_json,omitempty"`
}

type EvalDimension struct {
	Name      string  `json:"name"`
	FromStep  string  `json:"from_step"`
	FieldName string  `json:"field_name"`
	Weight    float64 `json:"weight"`
	MinScore  int64   `json:"min_score"`
}

// ─────────────────────────────────────────────────────────────────────────────
// EXECUTION PLAN
// ─────────────────────────────────────────────────────────────────────────────

type ExecutionPlan struct {
	Steps      []PipelineStep `json:"steps"`
	StrictMode bool           `json:"strict_mode"`
}

func ParseExecutionPlan(data []byte) (*ExecutionPlan, error) {
	var plan ExecutionPlan
	if err := json.Unmarshal(data, &plan); err != nil {
		return nil, fmt.Errorf("parse execution plan: %w", err)
	}
	if len(plan.Steps) == 0 {
		return nil, fmt.Errorf("execution plan has no steps")
	}
	last := plan.Steps[len(plan.Steps)-1]
	if last.Type != StepResolve {
		return nil, fmt.Errorf("last step must be RESOLVE, got %s", last.Type)
	}
	seen := make(map[string]bool)
	for _, s := range plan.Steps {
		if seen[s.Name] {
			return nil, fmt.Errorf("duplicate step name: %s", s.Name)
		}
		seen[s.Name] = true
	}
	for i, s := range plan.Steps {
		if s.InputStep != "" && !seen[s.InputStep] {
			return nil, fmt.Errorf("step %s references unknown input step %s", s.Name, s.InputStep)
		}
		if s.Gate != nil && s.Gate.FromStep != "" {
			priorNames := make(map[string]bool)
			for _, p := range plan.Steps[:i] {
				priorNames[p.Name] = true
			}
			if !priorNames[s.Gate.FromStep] {
				return nil, fmt.Errorf("step %s gate references future step %s", s.Name, s.Gate.FromStep)
			}
		}
	}
	return &plan, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP RESULT
//
// Typed output carried forward between steps.
// Each step type populates specific fields; others are zero.
// ─────────────────────────────────────────────────────────────────────────────

type StepResult struct {
	StepName string
	StepType StepType
	Skipped  bool
	Error    string

	// FINGERPRINT
	FingerprintScore int64
	FingerprintMatch bool
	ReferenceID      string

	// CLASSIFY
	ClassifiedTags []VerifiedTag

	// TRANSCRIBE
	SpeechPresent  bool
	Transcript     string
	KeywordMatches []string

	// EMBED
	SimilarityScore int64
	SimilarityMatch bool

	// EVALUATE
	QualityScore  int64
	QualityPassed bool
	DimScores     map[string]int64

	// RESOLVE
	OutcomeIndex int
	Confidence   int64
}

// ComposedTag is the output of a privacy-preserving tag composition pass.
// Produced by localShufflerCompose in step_executors.go. Defined here so
// ModelResponse (model_dispatch.go) and StepResult can reference it.
type ComposedTag struct {
	Name        string `json:"name"`
	MeanConfBps int64  `json:"mean_conf_bps"`
	DeviceCount int    `json:"device_count"`
	Present     bool   `json:"present"`
}

// ─────────────────────────────────────────────────────────────────────────────
// EXECUTION PLANNER
// ─────────────────────────────────────────────────────────────────────────────

type ExecutionPlanner struct {
	Plan    *ExecutionPlan
	Session *Session
	Results map[string]*StepResult
}

func NewExecutionPlanner(plan *ExecutionPlan, s *Session) *ExecutionPlanner {
	return &ExecutionPlanner{
		Plan:    plan,
		Session: s,
		Results: make(map[string]*StepResult),
	}
}

// Run executes all steps using the executor registry.
// Returns the RESOLVE step result, or an error if the plan aborts.
func (ep *ExecutionPlanner) Run() (*StepResult, error) {
	for _, step := range ep.Plan.Steps {
		result, err := ep.runStep(step)
		if err != nil {
			if ep.Plan.StrictMode {
				return nil, fmt.Errorf("step %s (strict): %w", step.Name, err)
			}
			log.Printf("[plan] step %s non-fatal: %v", step.Name, err)
			result = &StepResult{StepName: step.Name, StepType: step.Type,
				Skipped: true, Error: err.Error()}
		}
		ep.Results[step.Name] = result
		if result.Skipped {
			log.Printf("[plan] step %s skipped: %s", step.Name, result.Error)
		} else {
			log.Printf("[plan] step %s OK", step.Name)
		}
	}
	for _, step := range ep.Plan.Steps {
		if step.Type == StepResolve {
			if r, ok := ep.Results[step.Name]; ok {
				return r, nil
			}
		}
	}
	return nil, fmt.Errorf("no RESOLVE step executed")
}

func (ep *ExecutionPlanner) runStep(step PipelineStep) (*StepResult, error) {
	if step.Gate != nil {
		passed, reason, err := ep.evaluateGate(step.Gate)
		if err != nil {
			return nil, fmt.Errorf("gate: %w", err)
		}
		if !passed {
			if step.Gate.AbortOnFail {
				return nil, fmt.Errorf("gate abort: %s", reason)
			}
			return &StepResult{StepName: step.Name, StepType: step.Type,
				Skipped: true, Error: "gate: " + reason}, nil
		}
	}
	executor, err := defaultRegistry.Get(step.Type)
	if err != nil {
		return nil, err
	}
	return executor.Execute(step, ep.Results, ep.Session)
}

// ─────────────────────────────────────────────────────────────────────────────
// GATE EVALUATION
// ─────────────────────────────────────────────────────────────────────────────

func (ep *ExecutionPlanner) evaluateGate(g *StepGate) (bool, string, error) {
	switch g.Type {
	case GateMinScore:
		if g.FromStep == "" {
			return false, "", fmt.Errorf("MIN_SCORE gate requires from_step")
		}
		prior, ok := ep.Results[g.FromStep]
		if !ok || prior.Skipped {
			return false, fmt.Sprintf("prior step %s not available", g.FromStep), nil
		}
		score := scoreFromResult(prior, g.Reference)
		if score < g.Threshold {
			return false, fmt.Sprintf("%s score %d < %d", g.Reference, score, g.Threshold), nil
		}
		return true, "", nil

	case GateTagPresent:
		if ep.Session.Summary == nil {
			return false, "no evidence summary", nil
		}
		for _, ve := range ep.Session.Summary.Verified {
			for _, tag := range ve.Tags {
				if tag.Name == g.Reference && int64(tag.Confidence) >= g.Threshold {
					return true, "", nil
				}
			}
		}
		return false, fmt.Sprintf("tag %s not present above %d bps", g.Reference, g.Threshold), nil

	case GateMinDevices:
		if ep.Session.Summary == nil {
			return false, "no evidence summary", nil
		}
		count := int64(ep.Session.Summary.VerifiedDevices)
		if count < g.Threshold {
			return false, fmt.Sprintf("%d devices < %d required", count, g.Threshold), nil
		}
		return true, "", nil

	case GateFieldTrue:
		if g.FromStep == "" {
			return false, "", fmt.Errorf("FIELD_TRUE gate requires from_step")
		}
		prior, ok := ep.Results[g.FromStep]
		if !ok || prior.Skipped {
			return false, fmt.Sprintf("prior step %s not available", g.FromStep), nil
		}
		val := boolFieldFromResult(prior, g.Reference)
		if !val {
			return false, fmt.Sprintf("field %s is false in step %s", g.Reference, g.FromStep), nil
		}
		return true, "", nil

	case GateMinSessions:
		if ep.Session.Summary == nil {
			return false, "no evidence summary", nil
		}
		count := int64(ep.Session.Summary.VerifiedCount)
		if count < g.Threshold {
			return false, fmt.Sprintf("%d sessions < %d required", count, g.Threshold), nil
		}
		return true, "", nil

	default:
		return false, "", fmt.Errorf("unknown gate type: %s", g.Type)
	}
}

// scoreFromResult extracts a numeric metric from a StepResult by field name.
// Used by gate evaluation and EvaluateExecutor (step_executors.go).
func scoreFromResult(r *StepResult, field string) int64 {
	switch field {
	case "fingerprint_score":
		return r.FingerprintScore
	case "similarity_score":
		return r.SimilarityScore
	case "quality_score":
		return r.QualityScore
	case "confidence":
		return r.Confidence
	default:
		if r.DimScores != nil {
			return r.DimScores[field]
		}
		return 0
	}
}

// boolFieldFromResult extracts a boolean metric from a StepResult by field name.
func boolFieldFromResult(r *StepResult, field string) bool {
	switch field {
	case "fingerprint_match":
		return r.FingerprintMatch
	case "similarity_match":
		return r.SimilarityMatch
	case "speech_present":
		return r.SpeechPresent
	case "quality_passed":
		return r.QualityPassed
	default:
		return false
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// EXECUTION PLAN POSTPROCESSOR
//
// Plugs into the pipeline between EvidenceVerifyPostprocessor and
// DeterministicResolvePostprocessor. If the market has an ExecutionPlan,
// this runs it. If the context parses as a ResolutionFormula instead,
// this no-ops and the existing deterministic resolver takes over.
// ─────────────────────────────────────────────────────────────────────────────

type ExecutionPlanPostprocessor struct{}

func (p *ExecutionPlanPostprocessor) Name() string { return "ExecutionPlan" }

func (p *ExecutionPlanPostprocessor) Run(s *Session) error {
	// ResolutionDeterministic never reaches here (DeterministicResolvePostprocessor
	// aborts the session first). Guard anyway in case pipeline is misconfigured.
	if s.ResolutionMode == ResolutionDeterministic {
		return nil
	}
	// Already resolved by formula — nothing to do.
	if s.Resolution != nil {
		return nil
	}
	if s.Market == nil {
		return nil
	}
	plan, err := ParseExecutionPlan([]byte(s.Market.Context))
	if err != nil {
		return nil // not a plan — existing resolvers handle it
	}

	planner := NewExecutionPlanner(plan, s)
	finalResult, err := planner.Run()
	if err != nil {
		return fmt.Errorf("execution plan failed: %w", err)
	}

	if finalResult != nil && !finalResult.Skipped && finalResult.Confidence > 0 {
		s.Resolution = &ResolutionResult{
			OutcomeIndex: finalResult.OutcomeIndex,
			Confidence:   finalResult.Confidence,
		}
		if s.MarketKey != "" {
			s.Result.EncodedValue = EncodeResult(
				s.MarketKey,
				finalResult.OutcomeIndex,
				finalResult.Confidence,
			)
		}
		s.Result.Status = "Resolved"
		s.Result.Success = true
	}
	return nil
}
