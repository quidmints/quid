// pipeline.go — SAFTA Oracle Orchestrator
//
// This is the default execution frame for every TEE session.
// All existing oracle functions (resolve.go, deterministic_resolve.go,
// evidence_verify.go, validate.go, etc.) are post-processors that
// plug into this pipeline modularly.
//
// Architecture:
//
//   Trigger (CLI/Switchboard/CRE) → Orchestrator.Dispatch()
//       → selects Mode → builds Pipeline
//       → runs Preprocessors in order   (gate, enrich, validate-input)
//       → if any pre-processor aborts: return PreprocessError, skip post
//       → runs Postprocessors in order  (verify, resolve, attest, encode)
//       → flushes TEE state (zeroMemory) → return Result
//
// Modes (match entra.rs resolution_mode field):
//
//   ModeResolve       (0) — auto resolution: deterministic first, LLM fallback
//   ModeValidate      (1) — market creation validation (creation-time oracle)
//   ModeEvidenceGate  (2) — pre-submit evidence filtering (fingerprint + policy)
//   ModeForensics     (3) — dispute forensics (full evidence + LLM resolution)
//   ModeWatchdog      (4) — EVM depeg watchdog (CRE WASM path, see main.go)
//   ModeCoCoLocal     (5) — CoCo container local execution (classification)
//
// Pre-processor contract:
//   - Receives *Session, may enrich ctx.Input or ctx.Market
//   - Returns PreprocessResult with Abort bool + reason
//   - If Abort=true, pipeline stops and returns session.Result with that reason
//   - Preprocessors MUST NOT make external network calls (they run in DON mode)
//   - Exception: MarketStatePreprocessor reads Solana RPC (necessary gate)
//
// Post-processor contract:
//   - Receives *Session with ctx.Evidence / ctx.Market already populated
//   - May write to ctx.Resolution, ctx.ValidationResult, ctx.Tags
//   - Returns error; if non-nil, pipeline logs and continues (soft failure)
//   - PostprocessAbort error type causes hard stop (used for force-majeure)
//
// Session lifetime:
//   - Created per-trigger, NOT reused across triggers
//   - TEE has no persistence — all state lives in *Session
//   - FlushTEEState() called unconditionally at Dispatch() exit via defer
//   - Sensitive fields (API keys, audio buffers) tracked via TrackSensitive()

package main

import (
	"errors"
	"fmt"
	"log"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// MODE
// ─────────────────────────────────────────────────────────────────────────────

// Mode maps to resolution_mode in state.rs::MarketEvidence.
// TriggerMode is what kind of oracle invocation this is (from ORACLE_MODE env var).
type TriggerMode uint8

const (
	TriggerResolve  TriggerMode = 0 // post-deadline outcome resolution
	TriggerValidate TriggerMode = 1 // creation-time question qualification
)

func (t TriggerMode) String() string {
	switch t {
	case TriggerResolve:
		return "RESOLVE"
	case TriggerValidate:
		return "VALIDATE"
	default:
		return fmt.Sprintf("UNKNOWN(%d)", uint8(t))
	}
}

// ResolutionMode mirrors state.rs resolution_mode exactly.
// Read from MarketEvidenceData after loading the market. Drives pipeline selection.
//
// AI ROUTING RULES (enforced by DeterministicResolvePostprocessor):
//   ResolutionAuto (0):          formula first; if formula fails OR evidence insufficient,
//                                falls through to ExecutionPlanPostprocessor. Explicit opt-in
//                                to fallback — market must be created with mode=0.
//   ResolutionExternal (1):      AI always, formula skipped entirely. Model URI comes from
//                                market context (suggested by qualification oracle).
//   ResolutionDeterministic (3): formula only. If formula cannot resolve, session FAILS —
//                                no AI fallback, no ambiguous resolution.
//   All AI calls go through dispatchToModel → TeeML/CoCo. Never api.anthropic.com directly.
type ResolutionMode uint8

const (
	ResolutionAuto          ResolutionMode = 0 // deterministic first, explicit AI fallback
	ResolutionExternal      ResolutionMode = 1 // AI always (execution plan, no formula)
	ResolutionCoCoLocal     ResolutionMode = 2 // Switchboard CoCo Function only
	ResolutionDeterministic ResolutionMode = 3 // formula only, hard-fail if unresolvable
	ResolutionJuryOnly      ResolutionMode = 4 // no oracle verdict; TEE prepares evidence bundle
	ResolutionAIPlusJury    ResolutionMode = 5 // AI verdict + jury can override via LZ
)

// Mode is kept as an alias for pipeline registry keying during transition.
// New code should use TriggerMode / ResolutionMode directly.
type Mode = TriggerMode

// ModeResolve / ModeValidate / ModeEvidenceGate are the named pipeline keys
// used in the Registry. Defined as const to allow use in map literals and
// switch cases; they extend TriggerMode beyond the two env-driven values.
const (
	ModeResolve      TriggerMode = 0 // = TriggerResolve
	ModeValidate     TriggerMode = 1 // = TriggerValidate
	ModeEvidenceGate TriggerMode = 2 // pre-submit evidence filtering
	ModeForensics    TriggerMode = 3 // dispute forensics: full evidence + LLM
	ModeWatchdog     TriggerMode = 4 // depeg watchdog (CRE WASM path)
	ModeCoCoLocal    TriggerMode = 5 // Switchboard Function only, no LLM
)

// ─────────────────────────────────────────────────────────────────────────────
// SESSION
//
// Carries all state for a single TEE session. Passed by pointer through
// the full pre→post pipeline. Nothing here persists after Dispatch() returns.
// ─────────────────────────────────────────────────────────────────────────────

type Session struct {
	// ── Trigger metadata ──
	TriggerMode    TriggerMode
	ResolutionMode ResolutionMode // set by MarketStatePreprocessor from MarketEvidenceData
	MarketKey      string
	StartedAt      time.Time

	// ── Input (pre-processors may enrich this) ──
	Input SessionInput

	// ── Market and on-chain evidence data (populated from trigger payload) ──
	Market   *MarketData
	Evidence *MarketEvidenceData

	// ── Evidence (loaded by EvidenceVerifyPostprocessor) ──
	Summary *EvidenceSummary

	// ── Cross-provider privacy context ──
	// Populated by PrivacyBridgePreprocessor when market has a PrivacyManifest.
	// Flushed unconditionally at Dispatch() return.
	PrivacyCtx *PrivacyContext

	// ── Execution plan results ──
	// Populated by ExecutionPlanPostprocessor. Keyed by step name.
	// Read by LLM prompt builder in resolve.go via FormatPlanResultsForPrompt().
	PlanResults map[string]*StepResult

	// Adaptation blobs keyed by device pubkey hex. Loaded from off-chain storage at session start,
	// decrypted inside TEE. Each blob is 18KB: speaker embedding, vocab prior,
	// co-occurrence patterns, timbre profile — the contributor's productive signature.
	// Updated via EMA after successful evidence processing. Zeroed at Dispatch() return.
	AdaptationBlobs map[string]*AdaptationBlob

	// ── Outputs (written by post-processors) ──
	Resolution       *ResolutionResult
	ValidationResult *ValidationResult
	Tags             []AnalysisTag
	Attestation      *TEEAttestation

	// ── Pipeline result (set by Orchestrator before returning) ──
	Result SessionResult
}

// SessionInput holds the raw trigger payload.
// Fields are set by the trigger handler before calling Dispatch().
type SessionInput struct {
	// For RESOLVE / FORENSICS
	EvidenceSummaryJSON []byte // optional: pre-built summary (e.g. from Switchboard feed)

	// For VALIDATE
	Question         string
	Outcomes         []string
	Context          string
	Exculpatory      string
	ResolutionSource string
	HasEvidence      bool // market has device attestation requirements

	// For EVIDENCE_GATE (pre-submit filter)
	AudioFingerprintHash []byte // SHA256 of audio fingerprint
	DevicePubkey         []byte // compressed P-256 pubkey of submitting device

	// For COCO_LOCAL
	AudioData []byte // raw audio bytes (sensitive — tracked for zeroing)

	// General
	SampleIndex int // 0–2, for multi-sample LLM consensus

	// CRE path: pre-assembled verified evidence (no chain read).
	// When non-nil, EvidenceVerifyPostprocessor builds EvidenceSummary from this
	// directly instead of reading on-chain submissions.
	VerifiedEvidence []VerifiedEvidence

	// Optional model URI override (CRE path).
	ModelURIOverride string
}

// SessionResult is the final output of a pipeline execution.
type SessionResult struct {
	// Encoded return value for Switchboard PullFeed (resolve path)
	// Packed as: tag * TAG_MULTIPLIER + outcome * CONFIDENCE_MULTIPLIER + confidence
	EncodedValue int64

	// Human-readable status
	Status  string
	Reason  string
	Success bool

	// Errors from individual post-processors (soft failures)
	PostprocessErrors []string
}

// ─────────────────────────────────────────────────────────────────────────────
// PREPROCESSOR INTERFACE
// ─────────────────────────────────────────────────────────────────────────────

// PreprocessResult is returned by every Preprocessor.
type PreprocessResult struct {
	Abort  bool   // if true, pipeline stops immediately
	Reason string // human-readable explanation (logged + stored in Result)
}

// Preprocessor gates or enriches the session before any post-processing.
// Implementations: MarketStatePreprocessor, FingerprintPreprocessor,
// EvidenceWindowPreprocessor, DevicePolicyPreprocessor.
type Preprocessor interface {
	Name() string
	Run(s *Session) (*PreprocessResult, error)
}

// ─────────────────────────────────────────────────────────────────────────────
// POSTPROCESSOR INTERFACE
// ─────────────────────────────────────────────────────────────────────────────

// PostprocessAbort is a sentinel error that halts the post-processor chain.
// Use for unrecoverable conditions (e.g. force majeure detected mid-chain).
type PostprocessAbort struct {
	Reason string
}

func (e *PostprocessAbort) Error() string {
	return "postprocess abort: " + e.Reason
}

// Postprocessor performs the actual oracle work: evidence verification,
// resolution, validation, attestation.
// Implementations: EvidenceVerifyPostprocessor, DeterministicResolvePostprocessor,
// ExecutionPlanPostprocessor, ValidationPostprocessor, TEEAttestPostprocessor.
type Postprocessor interface {
	Name() string
	Run(s *Session) error
}

// ─────────────────────────────────────────────────────────────────────────────
// PIPELINE
//
// An ordered list of pre-processors + post-processors for a given Mode.
// Built by the Registry; not reused across sessions.
// ─────────────────────────────────────────────────────────────────────────────

type Pipeline struct {
	Mode          Mode
	Preprocessors []Preprocessor
	Postprocessors []Postprocessor
}

// Run executes the pipeline against a session.
// Preprocessors run first — if any aborts, post-processors are skipped.
// Post-processors run in order; PostprocessAbort halts the chain.
// Soft errors from post-processors are collected in Result.PostprocessErrors.
func (p *Pipeline) Run(s *Session) {
	log.Printf("[pipeline] mode=%s market=%s", p.Mode, s.MarketKey)

	// ── Pre-processors ──
	for _, pre := range p.Preprocessors {
		result, err := pre.Run(s)
		if err != nil {
			log.Printf("[pipeline] preprocessor %s error: %v", pre.Name(), err)
			s.Result = SessionResult{
				Status:  "PreprocessError",
				Reason:  fmt.Sprintf("%s: %v", pre.Name(), err),
				Success: false,
			}
			return
		}
		if result != nil && result.Abort {
			log.Printf("[pipeline] preprocessor %s aborted: %s", pre.Name(), result.Reason)
			s.Result = SessionResult{
				Status:  "Aborted",
				Reason:  fmt.Sprintf("%s: %s", pre.Name(), result.Reason),
				Success: false,
			}
			return
		}
		log.Printf("[pipeline] preprocessor %s OK", pre.Name())
	}

	// ── Post-processors ──
	for _, post := range p.Postprocessors {
		if err := post.Run(s); err != nil {
			var abort *PostprocessAbort
			if errors.As(err, &abort) {
				log.Printf("[pipeline] postprocessor %s ABORT: %s", post.Name(), abort.Reason)
				s.Result = SessionResult{
					Status:  "Aborted",
					Reason:  fmt.Sprintf("%s: %s", post.Name(), abort.Reason),
					Success: false,
					PostprocessErrors: s.Result.PostprocessErrors,
				}
				return
			}
			log.Printf("[pipeline] postprocessor %s soft error: %v", post.Name(), err)
			s.Result.PostprocessErrors = append(s.Result.PostprocessErrors,
				fmt.Sprintf("%s: %v", post.Name(), err))
		} else {
			log.Printf("[pipeline] postprocessor %s OK", post.Name())
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// BUILT-IN PREPROCESSORS
// ─────────────────────────────────────────────────────────────────────────────



// ─────────────────────────────────────────────────────────────────────────────
// BUILT-IN POSTPROCESSORS
// ─────────────────────────────────────────────────────────────────────────────

// EvidenceVerifyPostprocessor builds s.Summary from s.Input.VerifiedEvidence.
// Evidence arrives pre-assembled from the CRE trigger payload — no chain reads.
type EvidenceVerifyPostprocessor struct{}

func (p *EvidenceVerifyPostprocessor) Name() string { return "EvidenceVerify" }
func (p *EvidenceVerifyPostprocessor) Run(s *Session) error {
	// CRE path: evidence arrives pre-assembled in s.Input.VerifiedEvidence.
	// Build EvidenceSummary directly — no chain reads.
	if len(s.Input.VerifiedEvidence) == 0 {
		return nil
	}
	s.Summary = buildSummaryFromInput(s.Input.VerifiedEvidence)
	return nil
}

// DeterministicResolvePostprocessor attempts formula-based resolution.
//
// Behaviour by ResolutionMode (read from s.ResolutionMode):
//
//   ResolutionDeterministic (3):
//     Formula MUST resolve. If formula is missing, unparseable, or evidence is
//     insufficient, the session fails immediately. No AI fallback is permitted.
//     Market was created with this mode as an explicit commitment to zero-cost,
//     zero-ambiguity resolution.
//
//   ResolutionAuto (0):
//     Formula runs first. If it resolves, done. If formula is missing or evidence
//     is insufficient, sets s.Resolution = nil and returns nil — this is the
//     explicit opt-in signal for ExecutionPlanPostprocessor to proceed.
//
//   ResolutionExternal (1) / ResolutionCoCoLocal (2) / others:
//     Deterministic step is skipped entirely. AI or CoCo function is the
//     intended resolution path, not a fallback.
type DeterministicResolvePostprocessor struct{}

func (p *DeterministicResolvePostprocessor) Name() string { return "DeterministicResolve" }
func (p *DeterministicResolvePostprocessor) Run(s *Session) error {
	switch s.ResolutionMode {
	case ResolutionExternal, ResolutionCoCoLocal, ResolutionJuryOnly, ResolutionAIPlusJury:
		// AI / CoCo / jury is the primary path — skip deterministic entirely.
		return nil
	case ResolutionAuto, ResolutionDeterministic:
		// proceed below
	default:
		return nil
	}

	if s.Summary == nil || s.Market == nil {
		if s.ResolutionMode == ResolutionDeterministic {
			return &PostprocessAbort{Reason: "deterministic mode: no market or evidence data"}
		}
		return nil
	}
	if s.Evidence == nil || len(s.Evidence.RequiredTags) == 0 {
		if s.ResolutionMode == ResolutionDeterministic {
			return &PostprocessAbort{Reason: "deterministic mode: market has no formula (no required tags)"}
		}
		return nil // ResolutionAuto: fall through to execution plan
	}

	formula, err := ParseFormula([]byte(s.Market.Context))
	if err != nil {
		if s.ResolutionMode == ResolutionDeterministic {
			return &PostprocessAbort{Reason: fmt.Sprintf("deterministic mode: formula parse failed: %v", err)}
		}
		log.Printf("[DeterministicResolve] no parseable formula in context: %v", err)
		return nil // ResolutionAuto: fall through to execution plan
	}

	res, resolved := TryDeterministicResolve(formula, s.Summary)
	if !resolved {
		if s.ResolutionMode == ResolutionDeterministic {
			return &PostprocessAbort{Reason: fmt.Sprintf("deterministic mode: insufficient evidence — %s", res.Reason)}
		}
		log.Printf("[DeterministicResolve] insufficient evidence: %s — falling through to execution plan (mode=auto)", res.Reason)
		return nil // ResolutionAuto explicit fallback opt-in
	}

	log.Printf("[DeterministicResolve] resolved: outcome=%d confidence=%d reason=%s",
		res.Outcome, res.Confidence, res.Reason)

	s.Resolution = &ResolutionResult{
		OutcomeIndex: res.Outcome,
		Confidence:   int64(res.Confidence),
	}
	if s.MarketKey != "" {
		s.Result.EncodedValue = EncodeResult(s.MarketKey, res.Outcome, int64(res.Confidence))
	}
	s.Result.Status = "Resolved"
	s.Result.Reason = res.Reason
	s.Result.Success = true
	return nil
}

// ValidationPostprocessor runs creation-time question validation.
// Writes to s.ValidationResult. Only used in ModeValidate pipeline.
type ValidationPostprocessor struct{}

func (p *ValidationPostprocessor) Name() string { return "Validate" }
func (p *ValidationPostprocessor) Run(s *Session) error {
	in := s.Input
	if in.Question == "" {
		return fmt.Errorf("no question to validate")
	}
	result, err := ValidateQuestion(
		in.Question,
		in.Outcomes,
		in.ResolutionSource,
		in.Context,
		in.Exculpatory,
		in.HasEvidence,
	)
	if err != nil {
		return fmt.Errorf("validation failed: %w", err)
	}
	s.ValidationResult = result

	// Encode: content_tag * TAG_MULTIPLIER + approved(0|1) * CONFIDENCE_MULTIPLIER + score
	// content_tag from SHA256(question || context || exculpatory)
	tag := MarketTag(in.Question + in.Context + in.Exculpatory) // reuse hash logic
	approved := int64(0)
	if result.Approved {
		approved = 1
	}
	s.Result.EncodedValue = int64(tag)*TAG_MULTIPLIER + approved*CONFIDENCE_MULTIPLIER + result.Score
	s.Result.Status = "Validated"
	s.Result.Reason = result.Reason
	s.Result.Success = result.Approved
	return nil
}

// TEEAttestPostprocessor verifies the CoCo TEE attestation chain
// when s.Attestation is populated (by CoCoLocalPostprocessor or inbound RPC).
type TEEAttestPostprocessor struct {
	TrustedCodeHashes []string // SHA256 hashes of approved container images
}

func (p *TEEAttestPostprocessor) Name() string { return "TEEAttest" }
func (p *TEEAttestPostprocessor) Run(s *Session) error {
	if s.Attestation == nil {
		return nil // no attestation to verify in this session
	}
	return VerifyOnChainAttestation(s.Attestation, p.TrustedCodeHashes)
}

// EncodeResultPostprocessor finalises the EncodedValue.
// Runs last in resolve pipelines to handle multi-winner markets.
type EncodeResultPostprocessor struct{}

func (p *EncodeResultPostprocessor) Name() string { return "EncodeResult" }
func (p *EncodeResultPostprocessor) Run(s *Session) error {
	if s.Resolution == nil || s.MarketKey == "" {
		return nil
	}
	// Single-winner (already set by Resolve postprocessors in most cases).
	// Multi-winner encoding happens here when Market.NumWinners > 1.
	if s.Market != nil && s.Market.NumWinners > 1 {
		// Bit-pack all outcomes <= resolution confidence as winners.
		// Threshold: confidence > 5000 bps = majority signal.
		// In practice, the resolution postprocessor picks the single best outcome.
		// Multi-winner support is a no-op unless the resolver explicitly sets
		// multiple outcomes. The Rust program handles the bitmask.
	}
	return nil
}

// ─────────────────────────────────────────────────────────────────────────────
// PIPELINE REGISTRY
//
// Maps Mode → Pipeline. Add new pipelines by registering them here.
// Custom pipelines (e.g. for specific market types) can override defaults
// by calling Registry.Register before Orchestrator.Dispatch().
// ─────────────────────────────────────────────────────────────────────────────

type Registry struct {
	pipelines map[TriggerMode]*Pipeline
}

func NewRegistry(trustedCodeHashes []string) *Registry {
	r := &Registry{pipelines: make(map[TriggerMode]*Pipeline)}

	// ModeResolve: market state + evidence gate → verify + deterministic + execution plan + encode
	// AI resolution goes through ExecutionPlanPostprocessor → dispatchToModel → TeeML/CoCo.
	r.Register(ModeResolve, &Pipeline{
		Mode: ModeResolve,
		Preprocessors: []Preprocessor{
		},
		Postprocessors: []Postprocessor{
			&EvidenceVerifyPostprocessor{},
			&DeterministicResolvePostprocessor{},
			&ExecutionPlanPostprocessor{},
			&EncodeResultPostprocessor{},
		},
	})

	// ModeValidate: no state load needed (creation-time, market doesn't exist yet)
	r.Register(ModeValidate, &Pipeline{
		Mode:          ModeValidate,
		Preprocessors: []Preprocessor{},
		Postprocessors: []Postprocessor{
			&ValidationPostprocessor{},
		},
	})

	// ModeEvidenceGate: load market state + evidence window, verify device signature
	r.Register(ModeEvidenceGate, &Pipeline{
		Mode: ModeEvidenceGate,
		Preprocessors: []Preprocessor{
		},
		Postprocessors: []Postprocessor{
			&EvidenceVerifyPostprocessor{},
			// FingerprintPreprocessor runs as post-processor here because
			// it needs the evidence summary to dedup against prior submissions.
			// Insert FingerprintPostprocessor (preprocess_fingerprint.go) here.
			&EncodeResultPostprocessor{},
		},
	})

	// ModeForensics: full pipeline — all evidence + execution plan AI step + TEE attestation
	r.Register(ModeForensics, &Pipeline{
		Mode: ModeForensics,
		Preprocessors: []Preprocessor{
		},
		Postprocessors: []Postprocessor{
			&EvidenceVerifyPostprocessor{},
			&ExecutionPlanPostprocessor{},
			&TEEAttestPostprocessor{TrustedCodeHashes: trustedCodeHashes},
			&EncodeResultPostprocessor{},
		},
	})

	// ModeWatchdog: handled by CRE WASM in main.go — not routed here.
	// Registered as a no-op so Dispatch doesn't error on mode 4.
	r.Register(ModeWatchdog, &Pipeline{
		Mode:           ModeWatchdog,
		Preprocessors:  []Preprocessor{},
		Postprocessors: []Postprocessor{},
	})

	// ModeCoCoLocal: TEE attestation verification + tag classification output
	r.Register(ModeCoCoLocal, &Pipeline{
		Mode: ModeCoCoLocal,
		Preprocessors: []Preprocessor{
		},
		Postprocessors: []Postprocessor{
			// Step executor pipeline (step_executors.go) goes here:
			// runs on-device model via ExecutionPlanPostprocessor, produces Tags + Attestation.
			&TEEAttestPostprocessor{TrustedCodeHashes: trustedCodeHashes},
		},
	})

	return r
}

func (r *Registry) Register(mode TriggerMode, p *Pipeline) {
	r.pipelines[mode] = p
}

// RegisterPostprocessor appends a postprocessor to an existing mode's pipeline.
// Use to add custom processors without rebuilding the full pipeline.
func (r *Registry) RegisterPostprocessor(mode TriggerMode, p Postprocessor) error {
	pipeline, ok := r.pipelines[mode]
	if !ok {
		return fmt.Errorf("no pipeline registered for mode %s", mode)
	}
	pipeline.Postprocessors = append(pipeline.Postprocessors, p)
	return nil
}

// RegisterPreprocessor prepends a preprocessor to an existing mode's pipeline.
func (r *Registry) RegisterPreprocessor(mode TriggerMode, p Preprocessor) error {
	pipeline, ok := r.pipelines[mode]
	if !ok {
		return fmt.Errorf("no pipeline registered for mode %s", mode)
	}
	pipeline.Preprocessors = append([]Preprocessor{p}, pipeline.Preprocessors...)
	return nil
}

// ─────────────────────────────────────────────────────────────────────────────
// ORCHESTRATOR
//
// Top-level entry point. One Orchestrator per binary instance.
// Thread-safe for concurrent trigger handling (Registry is read-only after init).
// ─────────────────────────────────────────────────────────────────────────────

type Orchestrator struct {
	Registry *Registry
}

func NewOrchestrator(_, _ string, trustedCodeHashes []string) *Orchestrator {
	return &Orchestrator{Registry: NewRegistry(trustedCodeHashes)}
}

// Dispatch routes a trigger to the appropriate pipeline and returns the result.
// FlushTEEState is called unconditionally on exit — no sensitive data survives.
func (o *Orchestrator) Dispatch(s *Session) SessionResult {
	defer func() {
		FlushTEEState()
		if s.PrivacyCtx != nil {
			s.PrivacyCtx.Flush()
		}
		for _, blob := range s.AdaptationBlobs {
			blob.Flush()
		}
	}()

	s.StartedAt = time.Now()

	// Track sensitive input buffers for zeroing
	if len(s.Input.AudioData) > 0 {
		TrackSensitive(s.Input.AudioData)
	}
	if len(s.Input.AudioFingerprintHash) > 0 {
		TrackSensitive(s.Input.AudioFingerprintHash)
	}

	pipeline, ok := o.Registry.pipelines[s.TriggerMode]
	if !ok {
		return SessionResult{
			Status:  "Error",
			Reason:  fmt.Sprintf("no pipeline registered for trigger %s", s.TriggerMode),
			Success: false,
		}
	}

	log.Printf("[orchestrator] dispatch trigger=%s resolution=%d market=%s",
		s.TriggerMode, s.ResolutionMode, s.MarketKey)
	pipeline.Run(s)

	elapsed := time.Since(s.StartedAt)
	log.Printf("[orchestrator] done trigger=%s status=%s elapsed=%v",
		s.TriggerMode, s.Result.Status, elapsed)

	return s.Result
}


// ─────────────────────────────────────────────────────────────────────────────
// MARKET STATE PREPROCESSOR — also sets s.ResolutionMode from MarketEvidence
// ─────────────────────────────────────────────────────────────────────────────

