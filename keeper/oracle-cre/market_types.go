// market_types.go — Market types and pure encoding functions.
//
// Extracted from svm/oracle/solana.go. Contains only the type definitions
// and pure math functions needed by the resolution pipeline.
// ReadMarketData and all RPC/borsh parsing is excluded — the CRE oracle
// receives market inputs directly in the trigger payload.

package main

// MarketData holds the fields the pipeline reads when evaluating a market.
// In the CRE oracle these are populated from OracleResolutionRequest,
// not from a Solana account.
type MarketData struct {
	Question         string
	Outcomes         []string
	Context          string
	Exculpatory      string
	ResolutionSource string
	ResolutionMode   uint8
	NumWinners       uint8
	Resolved         bool
	Cancelled        bool
	OutcomeIndex     int32
}

// MarketEvidenceData holds evidence requirements for a market.
// In the CRE oracle this is derived from the trigger payload.
// PipelineRoute describes a provider endpoint for a specific model class.
type PipelineRoute struct {
	ModelClass  uint8
	ProviderURI string
	Priority    uint8
}

type MarketEvidenceData struct {
	TimeWindowStart int64
	TimeWindowEnd   int64
	RequiredTags    [][32]byte
	MinSubmissions  uint32
	PipelineRoutes  []PipelineRoute
}

// AnalysisTag is a tag produced by a pipeline step (not device evidence).
type AnalysisTag struct {
	Name          string `json:"name"`
	ConfidenceBps int64  `json:"confidence_bps"`
	Source        string `json:"source"` // "model", "formula", "jury"
}

// TAG_MULTIPLIER / CONFIDENCE_MULTIPLIER mirror state.rs constants exactly.
const (
	TAG_MULTIPLIER        = int64(1_000_000_000)
	CONFIDENCE_MULTIPLIER = int64(1_000)
)

// MarketTag computes the 32-bit tag prefix from a market pubkey string.
// Deterministic: same pubkey always produces the same tag.
func MarketTag(marketPubkey string) uint32 {
	h := uint32(0)
	for _, c := range []byte(marketPubkey) {
		h = h*31 + uint32(c)
	}
	return h
}

// EncodeResult encodes a single-outcome resolution for the Switchboard PullFeed.
// Layout: tag * TAG_MULTIPLIER + outcomeIndex * CONFIDENCE_MULTIPLIER + confidence
func EncodeResult(marketPubkey string, outcomeIndex int, confidence int64) int64 {
	tag := int64(MarketTag(marketPubkey))
	return tag*TAG_MULTIPLIER + int64(outcomeIndex)*CONFIDENCE_MULTIPLIER + confidence
}

// EncodeResultMulti encodes a multi-outcome resolution.
// winnerIndices are packed into the confidence field as a bitmask.
func EncodeResultMulti(marketPubkey string, winnerIndices []int, confidence int64) int64 {
	tag := int64(MarketTag(marketPubkey))
	bitmask := int64(0)
	for _, idx := range winnerIndices {
		if idx < 62 {
			bitmask |= 1 << idx
		}
	}
	return tag*TAG_MULTIPLIER + bitmask*CONFIDENCE_MULTIPLIER + confidence
}
