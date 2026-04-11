// privacy_bridge.go — Cross-Provider Privacy Bridge
//
// The TEE aggregates evidence from multiple providers and produces:
//   1. PUBLIC booleans → Switchboard PullFeed (visible on-chain)
//   2. TEEOnly evidence → used internally to derive the above; never exits enclave
//
// Jury resolution is EVM/Rust territory. The oracle produces its verdict
// and exits. Court.sol, FinalRuling, and LZ routing are not Go concerns.
//
// ─────────────────────────────────────────────────────────────────────────────
// TWO PRIVACY BANDS
// ─────────────────────────────────────────────────────────────────────────────
//
//   BandPublic   — boolean/commitment only → PullFeed
//   BandTEEOnly  — never exits enclave; used only to derive BandPublic outputs

package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"strings"
	"sync"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// PRIVACY BANDS
// ─────────────────────────────────────────────────────────────────────────────

type PrivacyBand uint8

const (
	BandPublic  PrivacyBand = 0 // boolean → PullFeed
	BandTEEOnly PrivacyBand = 1 // internal only; never exits enclave
)

func (b PrivacyBand) String() string {
	switch b {
	case BandPublic:
		return "PUBLIC"
	case BandTEEOnly:
		return "TEE_ONLY"
	default:
		return fmt.Sprintf("BAND(%d)", uint8(b))
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// WIRE TYPES — encrypted provider envelopes
// ─────────────────────────────────────────────────────────────────────────────

type EvidenceEnvelope struct {
	ProviderID    string              `json:"provider_id"`
	DataType      string              `json:"data_type"`
	MinBand       PrivacyBand         `json:"min_band"`
	Commitment    string              `json:"commitment,omitempty"` // hex SHA256
	Attestation   ProviderAttestation `json:"attestation"`
	EncryptedBody []byte              `json:"encrypted_body"`
	EphemeralPub  []byte              `json:"ephemeral_pub"` // P-256 compressed
	Nonce         []byte              `json:"nonce"`         // 12-byte GCM nonce
}

type ProviderAttestation struct {
	SignerKeyHex string `json:"signer_key"`
	Signature    string `json:"signature"` // ECDSA over SHA256(provider_id||data_type||commitment||nonce_hex)
	TEEReport    string `json:"tee_report,omitempty"`
}

// ─────────────────────────────────────────────────────────────────────────────
// RECORD TYPES — what providers send
// ─────────────────────────────────────────────────────────────────────────────

type ExistenceRecord struct {
	Exists    bool   `json:"exists"`
	RecordID  string `json:"record_id"`  // internal — never emitted
	Timestamp int64  `json:"timestamp"`
}

type MembershipRecord struct {
	Members    []string `json:"members"`     // wallet addresses or H(id||salt)
	RecordType string   `json:"record_type"` // "household", "marriage", "employment"
	ValidFrom  int64    `json:"valid_from"`
	ValidUntil int64    `json:"valid_until"` // 0 = indefinite
}

type MedicalRecord struct {
	SubjectHash   string `json:"subject_hash"`   // H(national_id||salt)
	Condition     string `json:"condition"`      // parties only
	Incapacitated bool   `json:"incapacitated"`
	DeceasedAt    int64  `json:"deceased_at"`    // 0 = alive
	CauseCategory string `json:"cause_category"` // "natural", "accident", "undetermined"
}

// ─────────────────────────────────────────────────────────────────────────────
// DECRYPTED EVIDENCE — TEE-internal only, zeroed at session end
// ─────────────────────────────────────────────────────────────────────────────

type DecryptedEvidence struct {
	ProviderID string
	DataType   string
	MinBand    PrivacyBand
	Body       []byte
	Commitment string
	Verified   bool
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVACY CONTEXT
// ─────────────────────────────────────────────────────────────────────────────

type PrivacyContext struct {
	mu            sync.Mutex
	evidence      map[string]*DecryptedEvidence
	publicOutputs []DisclosureOutput // → PullFeed
}

type DisclosureOutput struct {
	FactName    string      `json:"fact_name"`
	BoolValue   bool        `json:"bool_value"`
	DerivedFrom PrivacyBand `json:"derived_from"`
	Band        PrivacyBand `json:"band"`
}

func NewPrivacyContext() *PrivacyContext {
	return &PrivacyContext{evidence: make(map[string]*DecryptedEvidence)}
}

func (pc *PrivacyContext) store(e *DecryptedEvidence) {
	pc.mu.Lock()
	defer pc.mu.Unlock()
	pc.evidence[e.ProviderID+":"+e.DataType] = e
}

var ErrBandDenied = errors.New("band access denied")

func (pc *PrivacyContext) Get(providerID, dataType string) (*DecryptedEvidence, error) {
	pc.mu.Lock()
	defer pc.mu.Unlock()
	return pc.evidence[providerID+":"+dataType], nil
}

// EmitBoolean: any-band evidence → PUBLIC boolean → PullFeed
func (pc *PrivacyContext) EmitBoolean(factName string, value bool, sourceBand PrivacyBand) {
	pc.mu.Lock()
	defer pc.mu.Unlock()
	pc.publicOutputs = append(pc.publicOutputs, DisclosureOutput{
		FactName:    factName,
		BoolValue:   value,
		Band:        BandPublic,
		DerivedFrom: sourceBand,
	})
	log.Printf("[privacy] public %q=%v (from %s)", factName, value, sourceBand)
}

func (pc *PrivacyContext) PublicOutputs() []DisclosureOutput {
	pc.mu.Lock()
	defer pc.mu.Unlock()
	out := make([]DisclosureOutput, len(pc.publicOutputs))
	copy(out, pc.publicOutputs)
	return out
}

func (pc *PrivacyContext) Flush() {
	pc.mu.Lock()
	defer pc.mu.Unlock()
	for _, e := range pc.evidence {
		zeroMemory(e.Body)
		e.Body = nil
	}
	pc.evidence = make(map[string]*DecryptedEvidence)
	pc.publicOutputs = nil
}

// ─────────────────────────────────────────────────────────────────────────────
// TEE KEY MANAGEMENT
// ─────────────────────────────────────────────────────────────────────────────

var (
	teePrivateKey *ecdh.PrivateKey
	teePublicKey  *ecdh.PublicKey
	teeKeyOnce    sync.Once
	teeKeyMu      sync.Mutex
)

func InitTEEKey() error {
	var initErr error
	teeKeyOnce.Do(func() {
		key, err := ecdh.P256().GenerateKey(rand.Reader)
		if err != nil {
			initErr = fmt.Errorf("TEE key generation: %w", err)
			return
		}
		teePrivateKey = key
		teePublicKey = key.PublicKey()
		TrackSensitive(key.Bytes())
		log.Printf("[tee] ECDH key: %s...", hex.EncodeToString(teePublicKey.Bytes()[:8]))
	})
	return initErr
}

func TEEPublicKeyHex() (string, error) {
	teeKeyMu.Lock()
	defer teeKeyMu.Unlock()
	if teePublicKey == nil {
		return "", errors.New("TEE key not initialized")
	}
	return hex.EncodeToString(teePublicKey.Bytes()), nil
}

// ─────────────────────────────────────────────────────────────────────────────
// CRYPTO
// ─────────────────────────────────────────────────────────────────────────────

func decryptEnvelope(env *EvidenceEnvelope) ([]byte, error) {
	teeKeyMu.Lock()
	defer teeKeyMu.Unlock()
	if teePrivateKey == nil {
		return nil, errors.New("TEE key not initialized")
	}
	providerPub, err := ecdh.P256().NewPublicKey(env.EphemeralPub)
	if err != nil {
		return nil, fmt.Errorf("provider key: %w", err)
	}
	shared, err := teePrivateKey.ECDH(providerPub)
	if err != nil {
		return nil, fmt.Errorf("ECDH: %w", err)
	}
	defer zeroMemory(shared)

	h := sha256.New()
	h.Write([]byte("safta-evidence-key"))
	h.Write(shared)
	aesKey := h.Sum(nil)
	defer zeroMemory(aesKey)

	block, _ := aes.NewCipher(aesKey)
	gcm, _ := cipher.NewGCM(block)
	if len(env.Nonce) != gcm.NonceSize() {
		return nil, fmt.Errorf("nonce: %d != %d", len(env.Nonce), gcm.NonceSize())
	}
	return gcm.Open(nil, env.Nonce, env.EncryptedBody, nil)
}

func VerifyProviderAttestation(env *EvidenceEnvelope, registeredKeyHex string) error {
	if registeredKeyHex == "" {
		return fmt.Errorf("no registered key for %s", env.ProviderID)
	}
	msg := env.ProviderID + env.DataType + env.Commitment + hex.EncodeToString(env.Nonce)
	digest := sha256.Sum256([]byte(msg))

	keyBytes, err := hex.DecodeString(registeredKeyHex)
	if err != nil {
		return fmt.Errorf("key hex: %w", err)
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), keyBytes)
	if x == nil {
		x, y = elliptic.UnmarshalCompressed(elliptic.P256(), keyBytes)
	}
	if x == nil {
		return fmt.Errorf("invalid provider key")
	}
	pub := &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	sig, err := hex.DecodeString(env.Attestation.Signature)
	if err != nil || len(sig) != 64 {
		return fmt.Errorf("invalid signature")
	}
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return fmt.Errorf("attestation invalid: %s/%s", env.ProviderID, env.DataType)
	}
	return nil
}

func verifyCommitment(commitment string, body []byte) error {
	if commitment == "" {
		return nil
	}
	d := sha256.Sum256(body)
	if hex.EncodeToString(d[:]) != commitment {
		return fmt.Errorf("commitment mismatch")
	}
	return nil
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVACY MANIFEST — stored in Market.context or MarketEvidence
// ─────────────────────────────────────────────────────────────────────────────

type PrivacyManifest struct {
	Providers   []ProviderSpec   `json:"providers"`
	Disclosures []DisclosureRule `json:"disclosures"` // → BandPublic
}

type ProviderSpec struct {
	ProviderID       string      `json:"provider_id"`
	DataType         string      `json:"data_type"`
	MinBand          PrivacyBand `json:"min_band"`
	Required         bool        `json:"required"`
	RegisteredKeyHex string      `json:"registered_key"`
	FeedEndpoint     string      `json:"feed_endpoint"`
}

type DisclosureRule struct {
	OutputFact string   `json:"output_fact"`
	ProviderID string   `json:"provider_id"`
	DataType   string   `json:"data_type"`
	Evaluation EvalType `json:"evaluation"`
	Threshold  int64    `json:"threshold,omitempty"`
}

type EvalType string

const (
	EvalExists        EvalType = "EXISTS"
	EvalExistsSince   EvalType = "EXISTS_SINCE"
	EvalMemberOf      EvalType = "MEMBER_OF"
	EvalDeceased      EvalType = "DECEASED"
	EvalIncapacitated EvalType = "INCAPACITATED"
)

// ─────────────────────────────────────────────────────────────────────────────
// PRIVACY BRIDGE PREPROCESSOR
// ─────────────────────────────────────────────────────────────────────────────

type PrivacyBridgePreprocessor struct {
	Manifest *PrivacyManifest
}

func (p *PrivacyBridgePreprocessor) Name() string { return "PrivacyBridge" }

func (p *PrivacyBridgePreprocessor) Run(s *Session) (*PreprocessResult, error) {
	if p.Manifest == nil {
		return &PreprocessResult{Abort: false}, nil
	}
	ctx := NewPrivacyContext()
	for _, spec := range p.Manifest.Providers {
		env, err := fetchProviderEnvelope(spec)
		if err != nil {
			if spec.Required {
				return &PreprocessResult{true,
					fmt.Sprintf("required provider %s: %v", spec.ProviderID, err)}, nil
			}
			log.Printf("[bridge] optional %s: %v", spec.ProviderID, err)
			continue
		}
		if err := VerifyProviderAttestation(env, spec.RegisteredKeyHex); err != nil {
			if spec.Required {
				return &PreprocessResult{true,
					fmt.Sprintf("attestation failed %s: %v", spec.ProviderID, err)}, nil
			}
			continue
		}
		pt, err := decryptEnvelope(env)
		if err != nil {
			return &PreprocessResult{true,
				fmt.Sprintf("decrypt failed %s: %v", spec.ProviderID, err)}, nil
		}
		TrackSensitive(pt)
		if err := verifyCommitment(env.Commitment, pt); err != nil {
			return &PreprocessResult{true,
				fmt.Sprintf("commitment %s: %v", spec.ProviderID, err)}, nil
		}
		ctx.store(&DecryptedEvidence{
			ProviderID: spec.ProviderID, DataType: spec.DataType,
			MinBand: spec.MinBand, Body: pt, Commitment: env.Commitment, Verified: true,
		})
		log.Printf("[bridge] %s/%s OK (%d bytes)", spec.ProviderID, spec.DataType, len(pt))
	}
	s.PrivacyCtx = ctx
	return &PreprocessResult{Abort: false}, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// DISCLOSURE POSTPROCESSOR → BandPublic booleans for PullFeed
// ─────────────────────────────────────────────────────────────────────────────

type DisclosurePostprocessor struct{ Manifest *PrivacyManifest }

func (p *DisclosurePostprocessor) Name() string { return "Disclosure" }
func (p *DisclosurePostprocessor) Run(s *Session) error {
	if p.Manifest == nil || s.PrivacyCtx == nil {
		return nil
	}
	for _, rule := range p.Manifest.Disclosures {
		ev, _ := s.PrivacyCtx.Get(rule.ProviderID, rule.DataType)
		if ev == nil {
			continue
		}
		result, err := evaluateRule(rule.Evaluation, rule.Threshold, ev.Body)
		if err != nil {
			log.Printf("[disclosure] %q: %v", rule.OutputFact, err)
			continue
		}
		s.PrivacyCtx.EmitBoolean(rule.OutputFact, result, ev.MinBand)
	}
	return nil
}

func buildSummary(template string, eval EvalType, ev *DecryptedEvidence) string {
	if template != "" {
		return template
	}
	switch eval {
	case EvalDeceased:
		var rec MedicalRecord
		if json.Unmarshal(ev.Body, &rec) == nil && rec.DeceasedAt > 0 {
			return fmt.Sprintf("Death recorded %s, cause: %s",
				time.Unix(rec.DeceasedAt, 0).Format("2006-01-02"), rec.CauseCategory)
		}
		return "Subject alive as of evidence date"
	case EvalExists:
		var rec ExistenceRecord
		if json.Unmarshal(ev.Body, &rec) == nil {
			return fmt.Sprintf("Record exists: %v", rec.Exists)
		}
	case EvalMemberOf:
		var rec MembershipRecord
		if json.Unmarshal(ev.Body, &rec) == nil {
			return fmt.Sprintf("%s valid from %s", rec.RecordType,
				time.Unix(rec.ValidFrom, 0).Format("2006-01-02"))
		}
	}
	return fmt.Sprintf("%s/%s evaluated as %s", ev.ProviderID, ev.DataType, eval)
}

func evaluateRule(eval EvalType, threshold int64, body []byte) (bool, error) {
	now := time.Now().Unix()
	switch eval {
	case EvalExists:
		var rec ExistenceRecord
		if err := json.Unmarshal(body, &rec); err != nil {
			return false, err
		}
		return rec.Exists, nil
	case EvalExistsSince:
		var rec ExistenceRecord
		if err := json.Unmarshal(body, &rec); err != nil {
			return false, err
		}
		return rec.Exists && rec.Timestamp > 0 && (rec.Timestamp+threshold) <= now, nil
	case EvalMemberOf:
		var rec MembershipRecord
		if err := json.Unmarshal(body, &rec); err != nil {
			return false, err
		}
		return rec.ValidFrom > 0 && (rec.ValidUntil == 0 || rec.ValidUntil > now), nil
	case EvalDeceased:
		var rec MedicalRecord
		if err := json.Unmarshal(body, &rec); err != nil {
			return false, err
		}
		return rec.DeceasedAt > 0, nil
	case EvalIncapacitated:
		var rec MedicalRecord
		if err := json.Unmarshal(body, &rec); err != nil {
			return false, err
		}
		return rec.Incapacitated, nil
	default:
		return false, fmt.Errorf("unknown eval: %s", eval)
	}
}

func fetchProviderEnvelope(spec ProviderSpec) (*EvidenceEnvelope, error) {
	if spec.FeedEndpoint == "" {
		return nil, fmt.Errorf("no endpoint for %s", spec.ProviderID)
	}

	switch {
	case strings.HasPrefix(spec.FeedEndpoint, "switchboard:"):
		return fetchEnvelopeSwitchboard(spec)
	case strings.HasPrefix(spec.FeedEndpoint, "https://"):
		return fetchEnvelopeHTTPS(spec)
	default:
		return nil, fmt.Errorf("unsupported endpoint scheme: %s", spec.FeedEndpoint)
	}
}

// fetchEnvelopeSwitchboard is not available in the CRE oracle.
// Use https: endpoints or pass evidence directly in the trigger payload.
func fetchEnvelopeSwitchboard(spec ProviderSpec) (*EvidenceEnvelope, error) {
	return nil, fmt.Errorf("switchboard: evidence endpoints not supported in CRE oracle; use https: or inline evidence")
}

// fetchEnvelopeHTTPS fetches an EvidenceEnvelope from an HTTPS provider endpoint.
// The provider serves a signed JSON envelope at the given URL.
// mTLS is configured at the transport level via env (TLS_CERT_FILE / TLS_KEY_FILE).
func fetchEnvelopeHTTPS(spec ProviderSpec) (*EvidenceEnvelope, error) {
	body, err := doHTTPGet(spec.FeedEndpoint, map[string]string{
		"Accept":        "application/json",
		"X-Provider-ID": spec.ProviderID,
		"X-Data-Type":   spec.DataType,
	})
	if err != nil {
		return nil, fmt.Errorf("https evidence fetch: %w", err)
	}
	var env EvidenceEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("https envelope parse: %w", err)
	}
	return &env, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ─────────────────────────────────────────────────────────────────────────────
// SESSION EXTENSIONS — add to Session in pipeline.go
//
//   PrivacyCtx *PrivacyContext
//
// Add to Orchestrator.Dispatch() defer:
//   if s.PrivacyCtx != nil { s.PrivacyCtx.Flush() }
//
// Add to NewRegistry() for privacy-enabled modes:
//   Preprocessors:  []Preprocessor{&PrivacyBridgePreprocessor{}, &MarketStatePreprocessor{}, ...}
//   Postprocessors: []Postprocessor{&EvidenceVerifyPostprocessor{}, &DisclosurePostprocessor{}, &EncodeResultPostprocessor{}}
// ─────────────────────────────────────────────────────────────────────────────
