// deterministic_resolve.go — Formula-based market resolution (v3.2)
//
// Most SAFTA markets are boolean functions over tag conditions.
// No LLM needed. No cost. No latency.
//
// The market's on-chain EvidenceRequirements specify a formula.
// The oracle evaluates the formula against accumulated evidence
// and returns the outcome deterministically.
//
// v3.2 changes from v3.0:
//   - Uses EvidenceSummary from evidence_verify.go (domain aggregates)
//   - Tag conditions reference 502-tag registry (keccak hashes or names)
//   - Domain-level conditions: "any tag in speech.count domain"
//   - Pipeline route matching: direct evidence vs. inferred evidence
//   - Antispoof veto: auto-NO if antispoof alerts fire
//   - Weighted trend analysis using per-domain aggregation
//
// Formula types:
//   TAG_THRESHOLD:      single tag exceeds confidence threshold
//   TAG_RATIO:          ratio of tag occurrences across sessions
//   MULTI_TAG_AND:      multiple tags all above thresholds
//   MULTI_TAG_OR:       any tag above threshold
//   DOMAIN_THRESHOLD:   domain aggregate exceeds count/confidence threshold
//   DOMAIN_RATIO:       domain detection ratio across devices/sessions
//   CONVERSATION:       conversation quality metrics (composite)
//   TREND:              tag/domain metric improving/declining over window
//   PIPELINE_MATCH:     direct evidence from specific pipeline route
//
// If a market has no formula or the formula can't resolve (insufficient
// evidence), falls back to LLM resolution (resolve.go).

package main

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
)

// FormulaType identifies the resolution formula.
type FormulaType string

const (
	FormulaTagThreshold    FormulaType = "TAG_THRESHOLD"
	FormulaTagRatio        FormulaType = "TAG_RATIO"
	FormulaMultiTagAnd     FormulaType = "MULTI_TAG_AND"
	FormulaMultiTagOr      FormulaType = "MULTI_TAG_OR"
	FormulaDomainThreshold FormulaType = "DOMAIN_THRESHOLD"
	FormulaDomainRatio     FormulaType = "DOMAIN_RATIO"
	FormulaConversation    FormulaType = "CONVERSATION"
	FormulaTrend           FormulaType = "TREND"
	FormulaPipelineMatch   FormulaType = "PIPELINE_MATCH"
)

// ResolutionFormula stored in market's on-chain EvidenceRequirements.
// Serialized as JSON in the market account's `formula` field.
type ResolutionFormula struct {
	Type        FormulaType    `json:"type"`
	Conditions  []TagCondition `json:"conditions"`
	MinSessions uint32         `json:"min_sessions"` // minimum evidence submissions
	MinDevices  uint8          `json:"min_devices"`  // anti-spoofing: distinct devices

	// Veto: auto-NO if specific tags appear above threshold
	VetoTags []VetoCondition `json:"veto_tags,omitempty"`

	// Antispoof: auto-NO if any antispoof alerts fire
	AntispoofVeto bool `json:"antispoof_veto"`

	// Trend: time window for regression
	TrendWindow uint32 `json:"trend_window,omitempty"` // number of sessions

	// Pipeline: require evidence from specific pipeline route
	RequiredPipeline string `json:"required_pipeline,omitempty"` // provider_uri match
}

// TagCondition specifies a single condition in a formula.
// Can reference either a specific tag (by name or hash) or a domain.
type TagCondition struct {
	// Identify the tag — one of these should be set
	TagName string `json:"tag_name,omitempty"` // e.g. "SpeechDuet"
	TagHash string `json:"tag_hash,omitempty"` // keccak256 hex of tag name
	Domain  string `json:"domain,omitempty"`   // e.g. "speech.count" — matches any tag in domain

	// Threshold conditions (at least one should be set)
	MinBps   uint16  `json:"min_bps,omitempty"`   // min mean confidence (bps)
	MinRatio float64 `json:"min_ratio,omitempty"` // min fraction of sessions with tag
	MinCount int     `json:"min_count,omitempty"` // min total detection count

	// Trend direction (for FormulaTrend)
	Direction string `json:"direction,omitempty"` // "increasing" | "decreasing"

	// Weight for composite scoring (FormulaConversation)
	Weight float64 `json:"weight,omitempty"`
}

// VetoCondition: if this tag appears above threshold, market resolves NO.
type VetoCondition struct {
	TagName  string  `json:"tag_name,omitempty"`
	TagHash  string  `json:"tag_hash,omitempty"`
	Domain   string  `json:"domain,omitempty"`
	MaxRatio float64 `json:"max_ratio"` // if exceeded → veto
}

// Resolution is the output of deterministic resolution.
type Resolution struct {
	Outcome    int    `json:"outcome"`    // 0=YES, 1=NO, -1=indeterminate
	Confidence uint16 `json:"confidence"` // bps
	Reason     string `json:"reason"`
	Method     string `json:"method"` // "deterministic" | "insufficient" | "veto"
}

// ─────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────

// TryDeterministicResolve attempts to resolve a market using its formula.
// Returns (resolution, true) if resolved, or (nil, false) if LLM fallback needed.
//
// Uses EvidenceSummary from evidence_verify.go — already contains:
//   - DomainAggregates (tag counts grouped by domain)
//   - PipelineMatches (which pipeline routes were triggered)
//   - AntispoofAlerts (any flags from verified evidence)
//   - Verified[]  (individual verified evidence records with tags)
func TryDeterministicResolve(formula *ResolutionFormula,
	evidence *EvidenceSummary) (*Resolution, bool) {

	totalSessions := uint32(len(evidence.Verified))
	totalDevices := uint8(evidence.VerifiedDevices)

	// Check minimum evidence thresholds
	if totalSessions < formula.MinSessions {
		return &Resolution{
			Outcome: -1, Confidence: 0,
			Reason: fmt.Sprintf("insufficient sessions: %d < %d required",
				totalSessions, formula.MinSessions),
			Method: "insufficient",
		}, false
	}

	if totalDevices < formula.MinDevices {
		return &Resolution{
			Outcome: -1, Confidence: 0,
			Reason: fmt.Sprintf("insufficient devices: %d < %d required",
				totalDevices, formula.MinDevices),
			Method: "insufficient",
		}, false
	}

	// Antispoof veto: any spoof detected → automatic NO
	if formula.AntispoofVeto && len(evidence.AntispoofAlerts) > 0 {
		return &Resolution{
			Outcome: 1, Confidence: 9500,
			Reason: fmt.Sprintf("antispoof veto: %s",
				evidence.AntispoofAlerts[0]),
			Method: "veto",
		}, true
	}

	// Tag/domain veto checks
	for _, veto := range formula.VetoTags {
		if vetoed, reason := checkVeto(veto, evidence, totalSessions); vetoed {
			return &Resolution{
				Outcome: 1, Confidence: 9000,
				Reason:  reason,
				Method:  "veto",
			}, true
		}
	}

	// Pipeline requirement check
	if formula.RequiredPipeline != "" {
		found := false
		for _, pm := range evidence.PipelineMatches {
			if pm.ProviderURI == formula.RequiredPipeline && pm.IsDirectEvidence {
				found = true
				break
			}
		}
		if !found {
			return &Resolution{
				Outcome: -1, Confidence: 0,
				Reason: fmt.Sprintf("required pipeline %s not in evidence",
					formula.RequiredPipeline),
				Method: "insufficient",
			}, false
		}
	}

	// Dispatch to formula-specific resolver
	switch formula.Type {
	case FormulaTagThreshold:
		return resolveTagThreshold(formula, evidence, totalSessions)
	case FormulaTagRatio:
		return resolveTagRatio(formula, evidence, totalSessions)
	case FormulaMultiTagAnd:
		return resolveMultiTagAnd(formula, evidence, totalSessions)
	case FormulaMultiTagOr:
		return resolveMultiTagOr(formula, evidence, totalSessions)
	case FormulaDomainThreshold:
		return resolveDomainThreshold(formula, evidence)
	case FormulaDomainRatio:
		return resolveDomainRatio(formula, evidence)
	case FormulaConversation:
		return resolveConversation(formula, evidence, totalSessions)
	case FormulaTrend:
		return resolveTrend(formula, evidence)
	case FormulaPipelineMatch:
		return resolvePipelineMatch(formula, evidence)
	default:
		return nil, false
	}
}

// ─────────────────────────────────────────────────────────────────────
// VETO CHECK
// ─────────────────────────────────────────────────────────────────────

func checkVeto(veto VetoCondition, evidence *EvidenceSummary,
	totalSessions uint32) (bool, string) {

	if totalSessions == 0 {
		return false, ""
	}

	// Domain-level veto
	if veto.Domain != "" {
		for _, da := range evidence.DomainAggregates {
			if da.Domain == veto.Domain {
				ratio := float64(da.TotalCount) / float64(totalSessions)
				if ratio > veto.MaxRatio {
					return true, fmt.Sprintf("veto: domain %s ratio=%.1f%% > max %.1f%%",
						veto.Domain, ratio*100, veto.MaxRatio*100)
				}
			}
		}
		return false, ""
	}

	// Tag-level veto
	tagName := veto.TagName
	if tagName == "" && veto.TagHash != "" {
		tagName = veto.TagHash // fall back to hash for matching
	}

	count := countTagAcrossSessions(tagName, evidence)
	ratio := float64(count) / float64(totalSessions)
	if ratio > veto.MaxRatio {
		return true, fmt.Sprintf("veto: %s in %.0f%% of sessions (max %.0f%%)",
			tagName, ratio*100, veto.MaxRatio*100)
	}
	return false, ""
}

// ─────────────────────────────────────────────────────────────────────
// TAG-LEVEL RESOLVERS (operate on individual VerifiedTag entries)
// ─────────────────────────────────────────────────────────────────────

func resolveTagThreshold(f *ResolutionFormula, e *EvidenceSummary,
	total uint32) (*Resolution, bool) {

	if len(f.Conditions) == 0 {
		return nil, false
	}
	cond := f.Conditions[0]
	tagName := resolveTagName(cond)

	stats := computeTagStats(tagName, cond.Domain, e)
	if stats.sessionCount == 0 {
		return &Resolution{1, 8000,
			fmt.Sprintf("tag %s never observed", tagName),
			"deterministic"}, true
	}

	if stats.meanBps >= float64(cond.MinBps) {
		return &Resolution{0, uint16(stats.meanBps),
			fmt.Sprintf("tag %s mean=%.0f >= threshold=%d",
				tagName, stats.meanBps, cond.MinBps),
			"deterministic"}, true
	}

	return &Resolution{1, uint16(10000 - stats.meanBps),
		fmt.Sprintf("tag %s mean=%.0f < threshold=%d",
			tagName, stats.meanBps, cond.MinBps),
		"deterministic"}, true
}

func resolveTagRatio(f *ResolutionFormula, e *EvidenceSummary,
	total uint32) (*Resolution, bool) {

	if len(f.Conditions) == 0 || total == 0 {
		return nil, false
	}
	cond := f.Conditions[0]
	tagName := resolveTagName(cond)

	stats := computeTagStats(tagName, cond.Domain, e)
	ratio := float64(stats.sessionCount) / float64(total)

	if ratio >= cond.MinRatio {
		conf := uint16(math.Min(ratio*10000, 9500))
		return &Resolution{0, conf,
			fmt.Sprintf("tag %s ratio=%.1f%% >= %.1f%%",
				tagName, ratio*100, cond.MinRatio*100),
			"deterministic"}, true
	}

	return &Resolution{1, uint16((1 - ratio) * 10000),
		fmt.Sprintf("tag %s ratio=%.1f%% < %.1f%%",
			tagName, ratio*100, cond.MinRatio*100),
		"deterministic"}, true
}

func resolveMultiTagAnd(f *ResolutionFormula, e *EvidenceSummary,
	total uint32) (*Resolution, bool) {

	if total == 0 {
		return nil, false
	}

	minConf := uint16(10000)
	for _, cond := range f.Conditions {
		tagName := resolveTagName(cond)
		stats := computeTagStats(tagName, cond.Domain, e)

		if stats.sessionCount == 0 {
			return &Resolution{1, 8000,
				fmt.Sprintf("tag/domain %s never observed", tagName),
				"deterministic"}, true
		}

		ratio := float64(stats.sessionCount) / float64(total)

		if cond.MinRatio > 0 && ratio < cond.MinRatio {
			return &Resolution{1, uint16((1 - ratio) * 10000),
				fmt.Sprintf("tag %s ratio=%.1f%% < %.1f%%",
					tagName, ratio*100, cond.MinRatio*100),
				"deterministic"}, true
		}
		if cond.MinBps > 0 && stats.meanBps < float64(cond.MinBps) {
			return &Resolution{1, uint16(10000 - stats.meanBps),
				fmt.Sprintf("tag %s mean=%.0f < %d",
					tagName, stats.meanBps, cond.MinBps),
				"deterministic"}, true
		}

		conf := uint16(ratio * 10000)
		if conf < minConf {
			minConf = conf
		}
	}

	return &Resolution{0, minConf, "all conditions met", "deterministic"}, true
}

func resolveMultiTagOr(f *ResolutionFormula, e *EvidenceSummary,
	total uint32) (*Resolution, bool) {

	if total == 0 {
		return nil, false
	}

	bestConf := uint16(0)
	bestTag := ""

	for _, cond := range f.Conditions {
		tagName := resolveTagName(cond)
		stats := computeTagStats(tagName, cond.Domain, e)

		if stats.sessionCount == 0 {
			continue
		}

		ratio := float64(stats.sessionCount) / float64(total)
		met := false
		if cond.MinRatio > 0 {
			met = ratio >= cond.MinRatio
		}
		if cond.MinBps > 0 {
			met = met || stats.meanBps >= float64(cond.MinBps)
		}
		if met {
			conf := uint16(ratio * 10000)
			if conf > bestConf {
				bestConf = conf
				bestTag = tagName
			}
		}
	}

	if bestConf > 0 {
		return &Resolution{0, bestConf,
			fmt.Sprintf("condition met via %s", bestTag),
			"deterministic"}, true
	}
	return &Resolution{1, 8000, "no conditions met", "deterministic"}, true
}

// ─────────────────────────────────────────────────────────────────────
// DOMAIN-LEVEL RESOLVERS (operate on DomainAggregate from evidence_verify)
// ─────────────────────────────────────────────────────────────────────

func resolveDomainThreshold(f *ResolutionFormula,
	e *EvidenceSummary) (*Resolution, bool) {

	if len(f.Conditions) == 0 {
		return nil, false
	}
	cond := f.Conditions[0]
	if cond.Domain == "" {
		return nil, false // domain required for this formula type
	}

	da := findDomainAggregate(cond.Domain, e)
	if da == nil {
		return &Resolution{1, 8000,
			fmt.Sprintf("domain %s never observed", cond.Domain),
			"deterministic"}, true
	}

	// Check detection count
	if cond.MinCount > 0 && da.TotalCount < cond.MinCount {
		return &Resolution{1, uint16(float64(da.TotalCount) / float64(cond.MinCount) * 10000),
			fmt.Sprintf("domain %s count=%d < min=%d",
				cond.Domain, da.TotalCount, cond.MinCount),
			"deterministic"}, true
	}

	// Check average confidence
	if cond.MinBps > 0 {
		avgBps := uint16(da.AvgConfidence * 100) // AvgConfidence is 0-100, convert to bps concept
		if avgBps < cond.MinBps {
			return &Resolution{1, uint16(10000 - avgBps),
				fmt.Sprintf("domain %s avg_conf=%.1f < min=%d",
					cond.Domain, da.AvgConfidence, cond.MinBps),
				"deterministic"}, true
		}
	}

	conf := uint16(math.Min(float64(da.TotalCount)/float64(max(cond.MinCount, 1))*10000, 9500))
	return &Resolution{0, conf,
		fmt.Sprintf("domain %s: %d detections, avg_conf=%.1f",
			cond.Domain, da.TotalCount, da.AvgConfidence),
		"deterministic"}, true
}

func resolveDomainRatio(f *ResolutionFormula,
	e *EvidenceSummary) (*Resolution, bool) {

	if len(f.Conditions) == 0 {
		return nil, false
	}
	cond := f.Conditions[0]
	if cond.Domain == "" {
		return nil, false
	}

	da := findDomainAggregate(cond.Domain, e)
	if da == nil {
		return &Resolution{1, 8000,
			fmt.Sprintf("domain %s never observed", cond.Domain),
			"deterministic"}, true
	}

	// Ratio = unique devices with detections / total verified devices
	if e.VerifiedDevices == 0 {
		return nil, false
	}
	ratio := float64(da.UniqueDevices) / float64(e.VerifiedDevices)

	if ratio >= cond.MinRatio {
		conf := uint16(math.Min(ratio*10000, 9500))
		return &Resolution{0, conf,
			fmt.Sprintf("domain %s: %.0f%% of devices >= %.0f%% required",
				cond.Domain, ratio*100, cond.MinRatio*100),
			"deterministic"}, true
	}

	return &Resolution{1, uint16((1 - ratio) * 10000),
		fmt.Sprintf("domain %s: %.0f%% of devices < %.0f%% required",
			cond.Domain, ratio*100, cond.MinRatio*100),
		"deterministic"}, true
}

// ─────────────────────────────────────────────────────────────────────
// CONVERSATION (weighted composite across quality domains)
// ─────────────────────────────────────────────────────────────────────

func resolveConversation(f *ResolutionFormula, e *EvidenceSummary,
	total uint32) (*Resolution, bool) {

	if total == 0 || len(f.Conditions) == 0 {
		return nil, false
	}

	// Conversation formula: weighted sum across multiple tag/domain conditions.
	// Each condition contributes weight × (normalized score).
	// If total weighted score > 0.5 → YES, else NO.
	var totalWeight, weightedScore float64

	for _, cond := range f.Conditions {
		w := cond.Weight
		if w == 0 {
			w = 1.0 // default weight
		}
		totalWeight += w

		tagName := resolveTagName(cond)
		var score float64

		if cond.Domain != "" {
			// Domain-level scoring
			da := findDomainAggregate(cond.Domain, e)
			if da != nil {
				// Normalize: count relative to threshold, capped at 1.0
				if cond.MinCount > 0 {
					score = math.Min(float64(da.TotalCount)/float64(cond.MinCount), 1.0)
				} else {
					score = math.Min(da.AvgConfidence/100.0, 1.0)
				}
			}
		} else {
			// Tag-level scoring
			stats := computeTagStats(tagName, "", e)
			if stats.sessionCount > 0 {
				if cond.MinBps > 0 {
					score = math.Min(stats.meanBps/float64(cond.MinBps), 1.0)
				} else if cond.MinRatio > 0 {
					ratio := float64(stats.sessionCount) / float64(total)
					score = math.Min(ratio/cond.MinRatio, 1.0)
				} else {
					score = math.Min(stats.meanBps/10000.0, 1.0)
				}
			}
		}

		weightedScore += w * score
	}

	if totalWeight == 0 {
		return nil, false
	}

	normalized := weightedScore / totalWeight // 0.0 - 1.0
	conf := uint16(normalized * 10000)

	if normalized >= 0.5 {
		return &Resolution{0, conf,
			fmt.Sprintf("conversation score=%.1f%% (threshold=50%%)", normalized*100),
			"deterministic"}, true
	}

	return &Resolution{1, 10000 - conf,
		fmt.Sprintf("conversation score=%.1f%% < 50%%", normalized*100),
		"deterministic"}, true
}

// ─────────────────────────────────────────────────────────────────────
// TREND (linear regression over session history)
// ─────────────────────────────────────────────────────────────────────

func resolveTrend(f *ResolutionFormula, e *EvidenceSummary) (*Resolution, bool) {
	if len(e.Verified) < 2 || len(f.Conditions) == 0 {
		return nil, false
	}

	cond := f.Conditions[0]
	tagName := resolveTagName(cond)

	// Sort verified evidence by timestamp
	sorted := make([]VerifiedEvidence, len(e.Verified))
	copy(sorted, e.Verified)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].TimestampStart < sorted[j].TimestampStart
	})

	// Apply window
	window := f.TrendWindow
	if window == 0 || uint32(len(sorted)) < window {
		window = uint32(len(sorted))
	}
	sorted = sorted[len(sorted)-int(window):]

	// Extract tag confidence series
	var xs, ys []float64
	for i, ve := range sorted {
		xs = append(xs, float64(i))
		val := float64(0)

		if cond.Domain != "" {
			// Domain-level: count detections in this session for the domain
			for _, tag := range ve.Tags {
				if tag.Domain == cond.Domain {
					val += float64(tag.Confidence)
				}
			}
		} else {
			// Tag-level: confidence of specific tag
			for _, tag := range ve.Tags {
				if tag.Name == tagName {
					if float64(tag.Confidence) > val {
						val = float64(tag.Confidence)
					}
				}
			}
		}
		ys = append(ys, val)
	}

	slope := linearSlope(xs, ys)
	increasing := slope > 0
	match := (cond.Direction == "increasing" && increasing) ||
		(cond.Direction == "decreasing" && !increasing)

	absSl := math.Abs(slope)
	conf := uint16(math.Min(absSl*100, 9500))

	if match {
		return &Resolution{0, conf,
			fmt.Sprintf("%s trending %s (slope=%.2f over %d sessions)",
				tagName, cond.Direction, slope, len(sorted)),
			"deterministic"}, true
	}

	return &Resolution{1, conf,
		fmt.Sprintf("%s NOT trending %s (slope=%.2f over %d sessions)",
			tagName, cond.Direction, slope, len(sorted)),
		"deterministic"}, true
}

// ─────────────────────────────────────────────────────────────────────
// PIPELINE MATCH (direct evidence from specific provider/model)
// ─────────────────────────────────────────────────────────────────────

func resolvePipelineMatch(f *ResolutionFormula,
	e *EvidenceSummary) (*Resolution, bool) {

	if len(f.Conditions) == 0 {
		return nil, false
	}

	// Find the pipeline match that corresponds to the required pipeline
	var match *PipelineMatch
	for i := range e.PipelineMatches {
		pm := &e.PipelineMatches[i]
		if f.RequiredPipeline != "" && pm.ProviderURI != f.RequiredPipeline {
			continue
		}
		if pm.IsDirectEvidence {
			match = pm
			break
		}
	}

	if match == nil {
		return nil, false // no direct evidence from required pipeline
	}

	// Check conditions against matched tags
	for _, cond := range f.Conditions {
		tagName := resolveTagName(cond)
		found := false
		for _, mt := range match.MatchedTags {
			if mt == tagName {
				found = true
				break
			}
		}
		if !found {
			return &Resolution{1, 7000,
				fmt.Sprintf("pipeline %s: tag %s not matched",
					match.ProviderURI, tagName),
				"deterministic"}, true
		}
	}

	// All required tags matched in the pipeline evidence
	conf := uint16(math.Min(float64(match.SlotCount)*500, 9500))
	reason := fmt.Sprintf("pipeline %s: %d matched tags, %d slots",
		match.ProviderURI, len(match.MatchedTags), match.SlotCount)

	// Use verdict hint if available
	if match.VerdictHint != "" {
		reason += fmt.Sprintf(" (hint: %s)", match.VerdictHint)
	}

	return &Resolution{0, conf, reason, "deterministic"}, true
}

// ─────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────

// tagStats is an internal accumulator (not exported — avoids conflict
// with the EvidenceSummary types in evidence_verify.go).
type tagStats struct {
	sessionCount int
	meanBps      float64
	maxBps       uint16
}

// resolveTagName picks the human-readable name from a condition.
func resolveTagName(cond TagCondition) string {
	if cond.TagName != "" {
		return cond.TagName
	}
	if cond.Domain != "" {
		return cond.Domain
	}
	return cond.TagHash
}

// computeTagStats scans verified evidence for a specific tag or domain.
func computeTagStats(tagName, domain string, e *EvidenceSummary) tagStats {
	var stats tagStats

	for _, ve := range e.Verified {
		sessionHit := false
		for _, tag := range ve.Tags {
			match := false
			if domain != "" {
				match = tag.Domain == domain
			} else {
				match = tag.Name == tagName
			}
			if match {
				sessionHit = true
				bps := float64(tag.Confidence) * 100 // Confidence is 0-100, treat as bps/100
				if uint16(bps) > stats.maxBps {
					stats.maxBps = uint16(bps)
				}
				// Running mean
				stats.meanBps = stats.meanBps +
					(bps-stats.meanBps)/float64(stats.sessionCount+1)
			}
		}
		if sessionHit {
			stats.sessionCount++
		}
	}

	return stats
}

// countTagAcrossSessions counts how many sessions contain a specific tag.
func countTagAcrossSessions(tagName string, e *EvidenceSummary) int {
	count := 0
	for _, ve := range e.Verified {
		for _, tag := range ve.Tags {
			if tag.Name == tagName {
				count++
				break
			}
		}
	}
	return count
}

// findDomainAggregate looks up a domain in the pre-computed aggregates.
func findDomainAggregate(domain string, e *EvidenceSummary) *DomainAggregate {
	for i := range e.DomainAggregates {
		if e.DomainAggregates[i].Domain == domain {
			return &e.DomainAggregates[i]
		}
	}
	return nil
}

// linearSlope computes ordinary least squares slope.
func linearSlope(xs, ys []float64) float64 {
	n := float64(len(xs))
	if n < 2 {
		return 0
	}
	var sx, sy, sxx, sxy float64
	for i := range xs {
		sx += xs[i]
		sy += ys[i]
		sxx += xs[i] * xs[i]
		sxy += xs[i] * ys[i]
	}
	denom := n*sxx - sx*sx
	if denom == 0 {
		return 0
	}
	return (n*sxy - sx*sy) / denom
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// ─────────────────────────────────────────────────────────────────────
// PARSING / AGGREGATION
// ─────────────────────────────────────────────────────────────────────

// ParseFormula deserializes a resolution formula from on-chain JSON.
func ParseFormula(data []byte) (*ResolutionFormula, error) {
	var f ResolutionFormula
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("parse formula: %w", err)
	}
	if f.Type == "" {
		return nil, fmt.Errorf("formula missing type field")
	}
	return &f, nil
}
