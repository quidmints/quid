// model_types.go — Shared model request/response types and storage interface.
//
// No build tag — compiled on both Switchboard (!wasip1) and CRE (wasip1) targets.
// Dispatch implementations live in model_dispatch.go (!wasip1) and
// cre_model_dispatch.go (wasip1).

package main

// ─────────────────────────────────────────────────────────────────────────────
// REQUEST / RESPONSE TYPES
// ─────────────────────────────────────────────────────────────────────────────

type ModelRequest struct {
	StepType  StepType    `json:"step_type"`
	Params    StepParams  `json:"params"`
	InputData interface{} `json:"input_data"`
	MarketKey string      `json:"market_key"`
}

type ModelResponse struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`

	// FINGERPRINT
	MatchScore  int64  `json:"match_score,omitempty"`
	ReferenceID string `json:"reference_id,omitempty"`

	// CLASSIFY
	Tags []ClassifyTag `json:"tags,omitempty"`

	// TRANSCRIBE
	Transcript     string   `json:"transcript,omitempty"`
	Language       string   `json:"language,omitempty"`
	KeywordMatches []string `json:"keyword_matches,omitempty"`

	// EMBED
	SimilarityScore int64 `json:"similarity_score,omitempty"`

	// COMPOSED (shuffler output — used by localShufflerCompose in step_executors.go)
	ComposedTags []ComposedTag `json:"composed_tags,omitempty"`
}

// ClassifyTag is a single classifier output returned by a remote model.
// Distinct from VerifiedTag (device evidence) — this comes from a model endpoint.
type ClassifyTag struct {
	Name          string `json:"name"`
	ConfidenceBps int64  `json:"confidence_bps"`
	SlotCount     int    `json:"slot_count"`
}

// ZeroGStorageClient interface lives in storage.go to keep it alongside the implementation.
