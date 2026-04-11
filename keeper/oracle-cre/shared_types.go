// shared_types.go — Types shared across oracle-cre pipeline files.
//
// AdaptationBlob, ResolutionResult: needed by pipeline.go and execution_plan.go.
// EvidenceInput, EvidenceTagInput: the CRE trigger payload types.
// Kept in a tag-free file so both wasip1 (main.go) and test builds can use them.

package main

// ResolutionResult is the output of a successful resolution postprocessor.
type ResolutionResult struct {
	OutcomeIndex int
	Confidence   int64 // 0–10000 bps
}

// AdaptationBlob is a per-contributor biographical record stored on 0G Storage.
// 5MB fixed layout. Only the Merkle root is stored on-chain.
type AdaptationBlob struct {
	Data        []byte // raw blob (decrypted, zeroed after session)
	MerkleRoot  string // hex root for on-chain anchoring
	DeviceKey   string // device pubkey hex this blob belongs to
	EMAVersion  uint32 // monotonic version counter
}

// EvidenceInput is a single pre-assembled evidence unit from the CRE trigger payload.
// Mirrors the on-chain EvidenceData layout without chain-specific fields.
type EvidenceInput struct {
	TimestampStart int64              `json:"timestamp_start"`
	TimestampEnd   int64              `json:"timestamp_end"`
	GpsLat         int32              `json:"gps_lat,omitempty"`
	GpsLng         int32              `json:"gps_lng,omitempty"`
	Transcript     string             `json:"transcript,omitempty"`
	ContentType    uint8              `json:"content_type,omitempty"`
	HasPhoneCosig  bool               `json:"has_phone_cosig,omitempty"`
	BleRssi        int8               `json:"ble_rssi,omitempty"`
	Tags           []EvidenceTagInput `json:"tags,omitempty"`
}

// EvidenceTagInput is a single tag in an EvidenceInput.
type EvidenceTagInput struct {
	Name          string `json:"name"`            // e.g. "Speech", "Construction"
	Domain        string `json:"domain,omitempty"` // inferred if empty
	ConfidenceBps int    `json:"confidence_bps"`  // 0-100 scale (multiplied by 100 in pipeline)
	SlotCount     int    `json:"slot_count"`
}
