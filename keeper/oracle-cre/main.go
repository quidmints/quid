//go:build wasip1

// oracle-cre/main.go — SAFTA CRE Resolution Oracle
//
// A self-contained resolution engine that runs as a Chainlink CRE WASM workflow.
// Takes structured claims and evidence as trigger input; returns a verdict.
//
// No blockchain reads. The caller pre-assembles all inputs from whatever source
// is appropriate for their contract — UMA forensic evidence, insurance claims,
// delivery attestations, sports outcomes, or any structured dispute.
//
// Build:   GOOS=wasip1 GOARCH=wasm go build -o oracle.wasm .
// Simulate: cre workflow simulate <workflow> --trigger-index N --http-payload @req.json
//
// The depeg watchdog lives in keeper/ and is a completely separate binary.
// These two binaries share no code at runtime.
//
// Registered CRE steps:
//   "safta_resolve"   — full resolution pipeline
//   "safta_validate"  — pre-market validation (question + outcomes check)

package main

import (
	"encoding/json"
	"fmt"
	"log"

	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

// ─────────────────────────────────────────────────────────────────────────────
// INPUT
//
// OracleResolutionRequest is the complete trigger payload.
// The caller supplies everything — no chain is read inside the oracle.
//
// For UMA: map assertionId → MarketKey, the asserted claim → Question,
//   forensic evidence bundle → Evidence[], mode 3 (Deterministic) or 0 (Auto).
// For insurance: claimant statement → Question, sensor/medical data → Evidence[].
// For sports: match description → Question, outcomes → Outcomes[].
// ─────────────────────────────────────────────────────────────────────────────

type OracleResolutionRequest struct {
	// Opaque identifier echoed in the result — UMA assertionId, order ID, etc.
	MarketKey string `json:"market_key"`

	// Resolution question and possible outcomes
	Question         string   `json:"question"`
	Outcomes         []string `json:"outcomes"`
	Context          string   `json:"context"`
	Exculpatory      string   `json:"exculpatory,omitempty"`
	ResolutionSource string   `json:"resolution_source,omitempty"`

	// Resolution mode:
	//   0 = Auto     (formula first, AI fallback)
	//   1 = External (AI only via 0G/TeeML)
	//   2 = CoCoLocal (Switchboard CoCo function — requires model_uri)
	//   3 = Deterministic (formula only, hard-fail if unresolvable)
	ResolutionMode uint8 `json:"resolution_mode"`

	// Evidence pre-assembled by the caller.
	// For UMA: populate from the forensics callback data.
	// For device-attested markets: caller verifies device signatures
	// before submission; oracle treats these as already verified.
	Evidence []EvidenceInput `json:"evidence,omitempty"`

	// Optional: serialized execution plan JSON for AI-routed markets.
	// If empty, the oracle generates one from the question.
	ExecutionPlan string `json:"execution_plan,omitempty"`

	// Optional: model URI override for AI resolution steps.
	// Format: "0g:<provider_address>", "https://...", or "switchboard:<pubkey>"
	ModelURI string `json:"model_uri,omitempty"`
}

// EvidenceInput is a single pre-assembled evidence unit.
// Mirrors the on-chain EvidenceData layout but without chain-specific fields.
type EvidenceInput struct {
	TimestampStart  int64  `json:"timestamp_start"`
	TimestampEnd    int64  `json:"timestamp_end"`
	GpsLat          int32  `json:"gps_lat,omitempty"`
	GpsLng          int32  `json:"gps_lng,omitempty"`
	Transcript      string `json:"transcript,omitempty"`
	ContentType     uint8  `json:"content_type,omitempty"`
	HasPhoneCosig   bool   `json:"has_phone_cosig,omitempty"`
	BleRssi         int8   `json:"ble_rssi,omitempty"`
	Tags            []EvidenceTagInput `json:"tags,omitempty"`
}

type EvidenceTagInput struct {
	Name          string `json:"name"`           // tag label e.g. "Speech", "Construction"
	Domain        string `json:"domain,omitempty"` // inferred if empty
	ConfidenceBps int    `json:"confidence_bps"`
	SlotCount     int    `json:"slot_count"`
}

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

func main() {
	w := cre.NewWorkflow()

	w.AddStep("safta_resolve", func(ctx *cre.StepContext) (cre.Output, error) {
		return handleResolve(ctx)
	})
	w.AddStep("safta_validate", func(ctx *cre.StepContext) (cre.Output, error) {
		return handleValidate(ctx)
	})

	wasm.Run(w)
}

// ─────────────────────────────────────────────────────────────────────────────
// HANDLERS
// ─────────────────────────────────────────────────────────────────────────────

func handleResolve(ctx *cre.StepContext) (cre.Output, error) {
	var req OracleResolutionRequest
	if err := json.Unmarshal(ctx.Input, &req); err != nil {
		return cre.Output{}, fmt.Errorf("[oracle] bad input: %w", err)
	}
	if req.Question == "" || len(req.Outcomes) == 0 {
		return cre.Output{}, fmt.Errorf("[oracle] question and outcomes are required")
	}

	if err := InitTEEKey(); err != nil {
		return cre.Output{}, fmt.Errorf("[oracle] TEE key init: %w", err)
	}

	// Convert EvidenceInput → VerifiedEvidence for the pipeline.
	// The pipeline's EvidenceVerifyPostprocessor (chain-free version) will
	// build the EvidenceSummary from these directly.
	verified := make([]VerifiedEvidence, 0, len(req.Evidence))
	for _, e := range req.Evidence {
		ve := VerifiedEvidence{
			TimestampStart: e.TimestampStart,
			TimestampEnd:   e.TimestampEnd,
			GpsLat:         float64(e.GpsLat) / 1e7,
			GpsLng:         float64(e.GpsLng) / 1e7,
			HasPhoneCosig:  e.HasPhoneCosig,
			BleRssi:        e.BleRssi,
			BleIntegrity:   classifyBleRssi(e.BleRssi),
			ContentType:    e.ContentType,
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
		verified = append(verified, ve)
	}

	// Build session — no RPCURL or ProgramID needed.
	s := &Session{
		TriggerMode:    TriggerResolve,
		MarketKey:      req.MarketKey,
		ResolutionMode: ResolutionMode(req.ResolutionMode),
		Input: SessionInput{
			Question:         req.Question,
			Outcomes:         req.Outcomes,
			Context:          req.Context,
			Exculpatory:      req.Exculpatory,
			ResolutionSource: req.ResolutionSource,
			VerifiedEvidence: verified,
			ExecutionPlan:    req.ExecutionPlan,
		},
	}
	if req.ModelURI != "" {
		s.Input.ModelURIOverride = req.ModelURI
	}

	o := NewOrchestrator("", "", nil)
	r := o.Dispatch(s)
	return encodeOutput(&r)
}

func handleValidate(ctx *cre.StepContext) (cre.Output, error) {
	var req OracleResolutionRequest
	if err := json.Unmarshal(ctx.Input, &req); err != nil {
		return cre.Output{}, fmt.Errorf("[oracle] bad validate input: %w", err)
	}

	if err := InitTEEKey(); err != nil {
		return cre.Output{}, fmt.Errorf("[oracle] TEE key init: %w", err)
	}

	s := &Session{
		TriggerMode: TriggerValidate,
		MarketKey:   req.MarketKey,
		Input: SessionInput{
			Question:         req.Question,
			Outcomes:         req.Outcomes,
			Context:          req.Context,
			Exculpatory:      req.Exculpatory,
			ResolutionSource: req.ResolutionSource,
		},
	}
	o := NewOrchestrator("", "", nil)
	r := o.Dispatch(s)
	return encodeOutput(&r)
}

// encodeOutput packs a SessionResult into a CRE output envelope.
func encodeOutput(r *SessionResult) (cre.Output, error) {
	if !r.Success {
		log.Printf("[oracle] pipeline error: %s — %s", r.Status, r.Reason)
	}
	raw, err := json.Marshal(r)
	if err != nil {
		return cre.Output{}, fmt.Errorf("[oracle] marshal result: %w", err)
	}
	return cre.Output{
		Value: r.EncodedValue,
		Metadata: map[string]interface{}{
			"session_result": string(raw),
			"success":        r.Success,
			"status":         r.Status,
			"market_key":     r.MarketKey,
		},
	}, nil
}
