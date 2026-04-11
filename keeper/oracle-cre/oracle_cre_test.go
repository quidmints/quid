// oracle_cre_test.go — Unit tests for the CRE oracle resolution engine.
//
// All tests run locally without any network, CRE runtime, Chainlink DON,
// or external dependencies. Tests cover:
//   - buildSummaryFromInput (the chain-free evidence builder)
//   - OracleResolutionRequest → Session mapping
//   - Deterministic resolution via pre-assembled evidence
//   - market_types encoding (EncodeResult, MarketTag)
//   - classifyBleRssi, tagDomain helpers
//   - Full resolve pipeline end-to-end in deterministic mode
//   - Validate pipeline end-to-end (PreValidate)
//   - Edge cases: empty evidence, single device, antispoof veto

package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

// makeEvidence constructs an EvidenceInput slice with n devices each
// reporting the given tags at the given confidence (0-100 scale).
func makeEvidence(n int, tagConfs map[string]int) []EvidenceInput {
	evs := make([]EvidenceInput, n)
	for i := range evs {
		evs[i] = EvidenceInput{
			TimestampStart: int64(1_700_000_000 + i*3600),
			TimestampEnd:   int64(1_700_000_000 + i*3600 + 3600),
			BleRssi:        -50, // body-worn
			HasPhoneCosig:  true,
		}
		for name, conf := range tagConfs {
			evs[i].Tags = append(evs[i].Tags, EvidenceTagInput{
				Name:          name,
				Domain:        tagDomain(name),
				ConfidenceBps: conf,
				SlotCount:     4,
			})
		}
	}
	return evs
}

// buildVerified converts []EvidenceInput to []VerifiedEvidence the same way
// oracle-cre/main.go does in handleResolve.
func buildVerified(evs []EvidenceInput) []VerifiedEvidence {
	out := make([]VerifiedEvidence, 0, len(evs))
	for i, e := range evs {
		ve := VerifiedEvidence{
			DevicePubkeyHex: fmt.Sprintf("device%02x000000000000", i),
			TimestampStart:  e.TimestampStart,
			TimestampEnd:    e.TimestampEnd,
			HasPhoneCosig:   e.HasPhoneCosig,
			BleRssi:         e.BleRssi,
			BleIntegrity:    classifyBleRssi(e.BleRssi),
			ContentType:     e.ContentType,
		}
		for _, t := range e.Tags {
			domain := t.Domain
			if domain == "" {
				domain = tagDomain(t.Name)
			}
			ve.Tags = append(ve.Tags, VerifiedTag{
				Name:       t.Name,
				Domain:     domain,
				Confidence: t.ConfidenceBps,
				SlotCount:  t.SlotCount,
			})
		}
		out = append(out, ve)
	}
	return out
}

// runDeterministicResolve builds a session with pre-assembled evidence and
// runs just the DeterministicResolvePostprocessor — no network, no CRE runtime.
func runDeterministicResolve(t *testing.T, question string, formulaJSON string,
	evs []EvidenceInput) (*Session, error) {
	t.Helper()

	verified := buildVerified(evs)
	summary := buildSummaryFromInput(verified)

	s := &Session{
		MarketKey:      "CRETestMarket111111111111111111111111111",
		TriggerMode:    TriggerResolve,
		ResolutionMode: ResolutionDeterministic,
		Market: &MarketData{
			Question: question,
			Outcomes: []string{"Yes", "No"},
			Context:  formulaJSON,
		},
		Evidence: &MarketEvidenceData{
			RequiredTags: [][32]byte{{}},
		},
		Input: SessionInput{
			VerifiedEvidence: verified,
		},
		Summary: summary,
	}

	p := &DeterministicResolvePostprocessor{}
	err := p.Run(s)
	return s, err
}

// ─────────────────────────────────────────────────────────────────────────────
// buildSummaryFromInput
// ─────────────────────────────────────────────────────────────────────────────

func TestBuildSummaryFromInput_Empty(t *testing.T) {
	s := buildSummaryFromInput(nil)
	// buildSummaryFromInput always returns a non-nil summary;
	// empty input should produce zero counts.
	if s.TotalSubmissions != 0 {
		t.Errorf("expected 0 TotalSubmissions for nil input, got %d", s.TotalSubmissions)
	}
	if len(s.TagAggregation) != 0 {
		t.Errorf("expected empty TagAggregation for nil input")
	}
}

func TestBuildSummaryFromInput_SingleDevice(t *testing.T) {
	evs := []EvidenceInput{
		{
			TimestampStart: 1_700_000_000,
			TimestampEnd:   1_700_003_600,
			Tags: []EvidenceTagInput{
				{Name: "Construction", Domain: "construction", ConfidenceBps: 80, SlotCount: 5},
			},
		},
	}
	verified := buildVerified(evs)
	s := buildSummaryFromInput(verified)

	if s == nil {
		t.Fatal("expected non-nil summary")
	}
	if s.TotalSubmissions != 1 {
		t.Errorf("TotalSubmissions: want 1, got %d", s.TotalSubmissions)
	}
	if s.VerifiedCount != 1 {
		t.Errorf("VerifiedCount: want 1, got %d", s.VerifiedCount)
	}
	agg, ok := s.TagAggregation["Construction"]
	if !ok {
		t.Fatal("Construction not in TagAggregation")
	}
	if agg.TotalSlots != 5 {
		t.Errorf("TotalSlots: want 5, got %d", agg.TotalSlots)
	}
}

func TestBuildSummaryFromInput_MultiDevice(t *testing.T) {
	evs := makeEvidence(4, map[string]int{"Speech": 75, "Construction": 60})
	verified := buildVerified(evs)
	s := buildSummaryFromInput(verified)

	if s.TotalSubmissions != 4 {
		t.Errorf("TotalSubmissions: want 4, got %d", s.TotalSubmissions)
	}
	if s.VerifiedDevices != 4 {
		t.Errorf("VerifiedDevices: want 4, got %d", s.VerifiedDevices)
	}
	if len(s.TagAggregation) != 2 {
		t.Errorf("expected 2 tag aggregates, got %d", len(s.TagAggregation))
	}
}

func TestBuildSummaryFromInput_DomainAggregates(t *testing.T) {
	evs := makeEvidence(3, map[string]int{
		"Speech":       70,
		"Construction": 65,
		"HeavyMachinery": 60,
	})
	verified := buildVerified(evs)
	s := buildSummaryFromInput(verified)

	if len(s.DomainAggregates) == 0 {
		t.Error("expected non-empty DomainAggregates")
	}
	// Speech → speech domain, Construction + HeavyMachinery → construction domain
	found := map[string]bool{}
	for _, da := range s.DomainAggregates {
		found[da.Domain] = true
	}
	if !found["speech"] {
		t.Error("expected speech domain in aggregates")
	}
	if !found["construction"] {
		t.Error("expected construction domain in aggregates")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// MARKET ENCODING (oracle-cre uses same logic as Switchboard oracle)
// ─────────────────────────────────────────────────────────────────────────────

func TestMarketTag_Stable(t *testing.T) {
	key := "CREMarketKeyForTesting1234567890ABCDE"
	if MarketTag(key) != MarketTag(key) {
		t.Error("MarketTag must be stable")
	}
}

func TestEncodeResult_YesNoDiffer(t *testing.T) {
	key := "CREMarketKeyForTesting1234567890ABCDE"
	yes := EncodeResult(key, 0, 7500)
	no := EncodeResult(key, 1, 7500)
	if yes == no {
		t.Error("YES and NO must encode differently")
	}
}

func TestEncodeResult_Deterministic(t *testing.T) {
	key := "CREMarketKeyForTesting1234567890ABCDE"
	if EncodeResult(key, 0, 5000) != EncodeResult(key, 0, 5000) {
		t.Error("EncodeResult must be deterministic")
	}
}

func TestEncodeResultMulti_Bitmask(t *testing.T) {
	key := "CREMarketKeyForTesting1234567890ABCDE"
	confidence := int64(5000)
	r := EncodeResultMulti(key, []int{0, 2}, confidence)
	tag := int64(MarketTag(key))
	// Layout: tag*TAG_MULTIPLIER + bitmask*CONFIDENCE_MULTIPLIER + confidence
	bitmask := (r - tag*TAG_MULTIPLIER - confidence) / CONFIDENCE_MULTIPLIER
	if bitmask != 0b101 { // bit 0 (outcome 0) + bit 2 (outcome 2)
		t.Errorf("bitmask want 5 (0b101), got %d", bitmask)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// DETERMINISTIC PIPELINE — FULL PATH
// ─────────────────────────────────────────────────────────────────────────────

func TestCREResolve_TagThreshold_YES(t *testing.T) {
	formula := &ResolutionFormula{
		Type:        FormulaTagThreshold,
		Conditions:  []TagCondition{{TagName: "Construction", MinBps: 5000}},
		MinSessions: 2,
		MinDevices:  2,
	}
	formulaJSON, _ := json.Marshal(formula)

	evs := makeEvidence(3, map[string]int{"Construction": 75})
	s, err := runDeterministicResolve(t,
		"Was there active construction at the site during Q3 2025?",
		string(formulaJSON), evs)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s.Resolution == nil {
		t.Fatal("expected Resolution to be set")
	}
	if s.Resolution.OutcomeIndex != 0 {
		t.Errorf("expected YES (0), got %d", s.Resolution.OutcomeIndex)
	}
	if s.Result.EncodedValue == 0 {
		t.Error("EncodedValue should be non-zero after resolution")
	}
}

func TestCREResolve_TagThreshold_NO(t *testing.T) {
	formula := &ResolutionFormula{
		Type:        FormulaTagThreshold,
		Conditions:  []TagCondition{{TagName: "Construction", MinBps: 5000}},
		MinSessions: 2,
		MinDevices:  2,
	}
	formulaJSON, _ := json.Marshal(formula)

	// Low confidence (20 * 100 = 2000 bps < 5000 threshold)
	evs := makeEvidence(3, map[string]int{"Construction": 20})
	s, err := runDeterministicResolve(t,
		"Was there active construction at the site during Q3 2025?",
		string(formulaJSON), evs)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s.Resolution == nil {
		t.Fatal("expected Resolution")
	}
	if s.Resolution.OutcomeIndex != 1 {
		t.Errorf("expected NO (1) for low confidence, got %d", s.Resolution.OutcomeIndex)
	}
}

func TestCREResolve_MultiTagAnd_AllPresent(t *testing.T) {
	formula := &ResolutionFormula{
		Type: FormulaMultiTagAnd,
		Conditions: []TagCondition{
			{TagName: "Speech", MinBps: 4000},
			{TagName: "Construction", MinBps: 4000},
		},
		MinSessions: 2,
		MinDevices:  2,
	}
	formulaJSON, _ := json.Marshal(formula)

	evs := makeEvidence(3, map[string]int{"Speech": 70, "Construction": 65})
	s, err := runDeterministicResolve(t, "Was there a construction site with workers present during Q3 2025?",
		string(formulaJSON), evs)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s.Resolution == nil || s.Resolution.OutcomeIndex != 0 {
		outcome := -1
		if s.Resolution != nil {
			outcome = s.Resolution.OutcomeIndex
		}
		t.Errorf("expected YES, got outcome %d", outcome)
	}
}

func TestCREResolve_InsufficientDevices(t *testing.T) {
	formula := &ResolutionFormula{
		Type:        FormulaTagThreshold,
		Conditions:  []TagCondition{{TagName: "Construction", MinBps: 5000}},
		MinSessions: 5,
		MinDevices:  5,
	}
	formulaJSON, _ := json.Marshal(formula)

	// Only 2 devices — formula requires 5
	evs := makeEvidence(2, map[string]int{"Construction": 80})
	_, err := runDeterministicResolve(t, "Q3 2025 construction?", string(formulaJSON), evs)

	if err == nil {
		t.Error("expected PostprocessAbort for insufficient devices in deterministic mode")
	}
	if _, ok := err.(*PostprocessAbort); !ok {
		t.Errorf("expected *PostprocessAbort, got %T", err)
	}
}

func TestCREResolve_AntispoofVeto(t *testing.T) {
	formula := &ResolutionFormula{
		Type:          FormulaTagThreshold,
		Conditions:    []TagCondition{{TagName: "Construction", MinBps: 5000}},
		MinSessions:   2,
		MinDevices:    2,
		AntispoofVeto: true,
	}
	formulaJSON, _ := json.Marshal(formula)

	evs := makeEvidence(3, map[string]int{"Construction": 80})
	verified := buildVerified(evs)
	summary := buildSummaryFromInput(verified)
	summary.AntispoofAlerts = []string{"replay_detected"} // inject alert

	s := &Session{
		MarketKey:      "CRETestMarket111111111111111111111111111",
		TriggerMode:    TriggerResolve,
		ResolutionMode: ResolutionDeterministic,
		Market: &MarketData{
			Question: "Q3 2025 construction?",
			Outcomes: []string{"Yes", "No"},
			Context:  string(formulaJSON),
		},
		Evidence: &MarketEvidenceData{RequiredTags: [][32]byte{{}}},
		Input:    SessionInput{VerifiedEvidence: verified},
		Summary:  summary,
	}

	p := &DeterministicResolvePostprocessor{}
	err := p.Run(s)

	// Either aborts or resolves NO — either is correct for antispoof veto
	if err == nil && s.Resolution != nil && s.Resolution.OutcomeIndex == 0 {
		t.Error("antispoof veto should prevent YES outcome")
	}
}

func TestCREResolve_AutoMode_FallsThrough(t *testing.T) {
	// Auto mode with insufficient evidence should not hard-fail
	formula := &ResolutionFormula{
		Type:        FormulaTagThreshold,
		Conditions:  []TagCondition{{TagName: "Construction", MinBps: 5000}},
		MinSessions: 10, // requires 10
	}
	formulaJSON, _ := json.Marshal(formula)

	evs := makeEvidence(2, map[string]int{"Construction": 80})
	verified := buildVerified(evs)
	summary := buildSummaryFromInput(verified)

	s := &Session{
		MarketKey:      "CRETestMarket111111111111111111111111111",
		TriggerMode:    TriggerResolve,
		ResolutionMode: ResolutionAuto, // not deterministic — should fall through
		Market: &MarketData{
			Outcomes: []string{"Yes", "No"},
			Context:  string(formulaJSON),
		},
		Evidence: &MarketEvidenceData{RequiredTags: [][32]byte{{}}},
		Input:    SessionInput{VerifiedEvidence: verified},
		Summary:  summary,
	}

	p := &DeterministicResolvePostprocessor{}
	err := p.Run(s)
	if err != nil {
		t.Errorf("Auto mode should not abort, got: %v", err)
	}
	if s.Resolution != nil {
		t.Log("resolved deterministically despite low sessions — ok")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// PREVALIDATE (pure local — no LLM call)
// ─────────────────────────────────────────────────────────────────────────────

func TestCREPreValidate_ValidMarket(t *testing.T) {
	issues := PreValidate(
		"Was an active construction zone present at 51.5074°N, 0.1278°W during Q3 2025?",
		"UMA bonded assertion for Canary Wharf development monitoring",
		"Site may have been closed for bank holidays",
		[]string{"Yes", "No"},
	)
	if len(issues) > 0 {
		t.Errorf("expected clean validation, got: %v", issues)
	}
}

func TestCREPreValidate_VagueQuestion(t *testing.T) {
	issues := PreValidate(
		"Did something happen somewhere in 2025?",
		"", "", []string{"Yes", "No"},
	)
	if len(issues) == 0 {
		t.Error("expected issues for vague question")
	}
}

func TestCREPreValidate_EmptyQuestion(t *testing.T) {
	issues := PreValidate("", "", "", []string{"Yes", "No"})
	if len(issues) == 0 {
		t.Error("expected issues for empty question")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

func TestCREClassifyBleRssi(t *testing.T) {
	cases := []struct {
		rssi int8
		want string
	}{
		{-40, "body-worn"},
		{-60, "nearby"},
		{-80, "distant"},
		{-100, "disconnected"},
		{0, "no-data"},
	}
	for _, c := range cases {
		got := classifyBleRssi(c.rssi)
		if got != c.want {
			t.Errorf("classifyBleRssi(%d): want %q, got %q", c.rssi, c.want, got)
		}
	}
}

func TestCRETagDomain(t *testing.T) {
	if tagDomain("Speech") != "speech" {
		t.Error("Speech → speech")
	}
	if tagDomain("Construction") != "construction" {
		t.Error("Construction → construction")
	}
	if tagDomain("PlaybackDetected") != "spoofing" {
		t.Error("PlaybackDetected → spoofing")
	}
	if tagDomain("anything-unknown") != "other" {
		t.Error("unknown → other")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// PARSE FORMULA ROUND-TRIP
// ─────────────────────────────────────────────────────────────────────────────

func TestCREParseFormula_RoundTrip(t *testing.T) {
	orig := &ResolutionFormula{
		Type: FormulaMultiTagAnd,
		Conditions: []TagCondition{
			{TagName: "Speech", MinBps: 6000},
			{TagName: "Construction", MinBps: 4000},
		},
		MinSessions:   3,
		MinDevices:    2,
		AntispoofVeto: true,
		VetoTags: []VetoCondition{
			{TagName: "PlaybackDetected", MaxRatio: 0.2},
		},
	}
	data, _ := json.Marshal(orig)
	parsed, err := ParseFormula(data)
	if err != nil {
		t.Fatalf("ParseFormula: %v", err)
	}
	if parsed.Type != orig.Type {
		t.Errorf("Type: %s != %s", parsed.Type, orig.Type)
	}
	if len(parsed.Conditions) != 2 {
		t.Errorf("Conditions len: %d", len(parsed.Conditions))
	}
	if !parsed.AntispoofVeto {
		t.Error("AntispoofVeto not preserved")
	}
	if len(parsed.VetoTags) != 1 {
		t.Errorf("VetoTags len: %d", len(parsed.VetoTags))
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// UMA SCENARIO — matches the CRE oracle's primary use case
// ─────────────────────────────────────────────────────────────────────────────

func TestCREResolve_UMAScenario(t *testing.T) {
	// Simulate an UMA dispute: someone asserted "Construction was active at
	// Canary Wharf during Q3 2025". A challenger disputes it.
	// CRE oracle evaluates forensic evidence and returns a verdict.

	formula := &ResolutionFormula{
		Type: FormulaMultiTagAnd,
		Conditions: []TagCondition{
			{TagName: "Construction", MinBps: 5000},
			{TagName: "HeavyMachinery", MinBps: 3000},
		},
		MinSessions:   3,
		MinDevices:    2,
		AntispoofVeto: true,
	}
	formulaJSON, _ := json.Marshal(formula)

	// 4 devices submitted evidence confirming both construction and heavy machinery
	evs := makeEvidence(4, map[string]int{
		"Construction":   78,
		"HeavyMachinery": 65,
	})

	s, err := runDeterministicResolve(t,
		"Was there active construction and heavy machinery at Canary Wharf during Q3 2025?",
		string(formulaJSON), evs)

	if err != nil {
		t.Fatalf("UMA scenario resolution failed: %v", err)
	}
	if s.Resolution == nil {
		t.Fatal("no resolution produced")
	}
	if s.Resolution.OutcomeIndex != 0 {
		t.Errorf("expected assertion confirmed (YES=0), got %d, reason: %s",
			s.Resolution.OutcomeIndex, s.Result.Reason)
	}
	if s.Result.EncodedValue == 0 {
		t.Error("EncodedValue should be set for on-chain settlement")
	}
	if !s.Result.Success {
		t.Errorf("expected Success=true, got reason: %s", s.Result.Reason)
	}

	// Verify the encoded value can be decoded
	// Layout: tag*TAG_MULTIPLIER + outcomeIndex*CONFIDENCE_MULTIPLIER + confidence
	tag := int64(MarketTag(s.MarketKey))
	conf := s.Resolution.Confidence
	outcomeEncoded := (s.Result.EncodedValue - tag*TAG_MULTIPLIER - conf) / CONFIDENCE_MULTIPLIER
	if outcomeEncoded != 0 {
		t.Errorf("decoded outcome should be 0 (YES), got %d", outcomeEncoded)
	}

	t.Logf("UMA verdict: outcome=%d confidence=%d encoded=%d reason=%q",
		s.Resolution.OutcomeIndex, s.Resolution.Confidence,
		s.Result.EncodedValue, s.Result.Reason)
}

func TestCREResolve_UMAScenario_Disputed(t *testing.T) {
	// Same formula but evidence is weak — assertion should fail
	formula := &ResolutionFormula{
		Type: FormulaMultiTagAnd,
		Conditions: []TagCondition{
			{TagName: "Construction", MinBps: 5000},
			{TagName: "HeavyMachinery", MinBps: 3000},
		},
		MinSessions:   3,
		MinDevices:    2,
		AntispoofVeto: true,
	}
	formulaJSON, _ := json.Marshal(formula)

	// Only Construction present — HeavyMachinery absent
	evs := makeEvidence(3, map[string]int{"Construction": 72})

	s, err := runDeterministicResolve(t,
		"Was there active construction and heavy machinery at Canary Wharf during Q3 2025?",
		string(formulaJSON), evs)

	if err != nil {
		t.Fatalf("unexpected abort: %v", err)
	}
	if s.Resolution == nil {
		t.Fatal("expected resolution")
	}
	if s.Resolution.OutcomeIndex != 1 {
		t.Errorf("expected assertion denied (NO=1) when HeavyMachinery absent, got %d reason=%q",
			s.Resolution.OutcomeIndex, s.Result.Reason)
	}
	t.Logf("Dispute verdict: outcome=%d reason=%q", s.Resolution.OutcomeIndex, s.Result.Reason)
}

// ─────────────────────────────────────────────────────────────────────────────
// VALIDATE — PIPELINE
// ─────────────────────────────────────────────────────────────────────────────

func TestCREValidate_Pipeline_PrevalidateOnly(t *testing.T) {
	// ValidationPostprocessor calls ValidateQuestion which calls the LLM.
	// Test only the local PreValidate step, which is pure.
	question := "Was active construction underway at 51.5074°N, 0.1278°W during Q3 2025?"
	issues := PreValidate(question, "UMA forensics market", "", []string{"Yes", "No"})
	for _, issue := range issues {
		if strings.Contains(strings.ToLower(issue), "forbidden") ||
			strings.Contains(strings.ToLower(issue), "ambiguous") {
			t.Errorf("valid question flagged as problematic: %s", issue)
		}
	}
}
