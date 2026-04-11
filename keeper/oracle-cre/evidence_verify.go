// evidence_verify.go — Evidence types, helpers, and chain-free summary builder.
//
// In the CRE oracle, evidence arrives pre-assembled from the trigger payload
// (OracleResolutionRequest.Evidence). There are no on-chain submissions to
// read and no device signatures to re-verify — the caller is responsible for
// attestation before submitting the trigger.
//
// buildSummaryFromInput assembles EvidenceSummary from []VerifiedEvidence
// directly. VerifyDeviceSignature and VerifyAllEvidence are omitted here;
// add them back if you want the CRE oracle to re-verify P-256 signatures
// on evidence provided in the trigger payload.

package main

import (
	"crypto/sha256"
	"encoding/hex"
)

// ─────────────────────────────────────────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────────────────────────────────────────

type VerifiedEvidence struct {
	DevicePubkeyHex string
	Counter         uint32
	TimestampStart  int64
	TimestampEnd    int64
	GpsLat          float64
	GpsLng          float64
	Tags            []VerifiedTag
	SlotStart       uint32
	SlotEnd         uint32
	HasPhoneCosig   bool
	PhoneGpsLat     float64
	PhoneGpsLng     float64
	BleRssi         int8
	BleIntegrity    string
	HasMotionData   bool
	ContentType     uint8
}

type VerifiedTag struct {
	Name       string
	Domain     string
	Confidence int // bps
	SlotCount  int
}

type EvidenceSummary struct {
	TotalSubmissions int
	VerifiedCount    int
	RejectedCount    int
	RejectionReasons []string
	TagAggregation   map[string]TagAggregate
	DomainAggregates []DomainAggregate
	VerifiedDevices  int
	TimeCoverage     string
	Verified         []VerifiedEvidence
	AntispoofAlerts  []string
	PipelineMatches  []PipelineMatch
}

type PipelineMatch struct {
	ProviderURI      string
	IsDirectEvidence bool
	MatchedTags      []string
	SlotCount        int
	VerdictHint      string
}

type TagAggregate struct {
	DeviceCount   int
	AvgConfidence int
	TotalSlots    int
}

type DomainAggregate struct {
	Domain        string
	TotalCount    int
	AvgConfidence float64
	UniqueDevices int
}

// v1 taxonomy — 13 tags. tag_id = keccak256(name).
var knownTags = map[string]string{
	keccakHex("Silence"):            "Silence",
	keccakHex("Speech"):             "Speech",
	keccakHex("SpeechMultiple"):     "SpeechMultiple",
	keccakHex("Construction"):       "Construction",
	keccakHex("HeavyMachinery"):     "HeavyMachinery",
	keccakHex("VehicleTraffic"):     "VehicleTraffic",
	keccakHex("CommercialActivity"): "CommercialActivity",
	keccakHex("Music"):              "Music",
	keccakHex("Water"):              "Water",
	keccakHex("Alarm"):              "Alarm",
	keccakHex("Animal"):             "Animal",
	keccakHex("Unknown"):            "Unknown",
	keccakHex("PlaybackDetected"):   "PlaybackDetected",
}

func keccakHex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

var domainMap = map[string]string{
	"Speech": "speech", "SpeechMultiple": "speech",
	"Construction": "construction", "HeavyMachinery": "construction",
	"VehicleTraffic": "transport", "CommercialActivity": "commerce",
	"Music": "ambient", "Water": "ambient", "Animal": "ambient",
	"Alarm": "alert", "PlaybackDetected": "spoofing",
	"Silence": "silence", "Unknown": "other",
}

// ─────────────────────────────────────────────────────────────────────────────
// CHAIN-FREE SUMMARY BUILDER
//
// buildSummaryFromInput converts []VerifiedEvidence (from trigger payload)
// into the EvidenceSummary the pipeline expects. No RPC calls.
// ─────────────────────────────────────────────────────────────────────────────

func buildSummaryFromInput(evidence []VerifiedEvidence) *EvidenceSummary {
	summary := &EvidenceSummary{
		TotalSubmissions: len(evidence),
		VerifiedCount:    len(evidence),
		TagAggregation:   make(map[string]TagAggregate),
		Verified:         evidence,
	}

	for _, ve := range evidence {
		for _, tag := range ve.Tags {
			agg := summary.TagAggregation[tag.Name]
			agg.DeviceCount++
			agg.TotalSlots += tag.SlotCount
			if agg.DeviceCount == 1 {
				agg.AvgConfidence = tag.Confidence
			} else {
				agg.AvgConfidence = ((agg.AvgConfidence * (agg.DeviceCount - 1)) + tag.Confidence) / agg.DeviceCount
			}
			summary.TagAggregation[tag.Name] = agg
		}
	}

	summary.VerifiedDevices = countUniqueDevices(evidence)
	summary.DomainAggregates = buildDomainAggregates(evidence)
	return summary
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

func classifyBleRssi(rssi int8) string {
	if rssi == 0 {
		return "no-data"
	}
	if rssi >= -55 {
		return "body-worn"
	}
	if rssi >= -70 {
		return "nearby"
	}
	if rssi >= -85 {
		return "distant"
	}
	return "disconnected"
}

func tagDomain(name string) string {
	if d, ok := domainMap[name]; ok {
		return d
	}
	return "other"
}

func countUniqueDevices(verified []VerifiedEvidence) int {
	seen := make(map[string]bool)
	for _, v := range verified {
		seen[v.DevicePubkeyHex] = true
	}
	return len(seen)
}

func buildDomainAggregates(verified []VerifiedEvidence) []DomainAggregate {
	type acc struct {
		totalConf float64
		count     int
		devices   map[string]bool
	}
	m := make(map[string]*acc)
	for _, ve := range verified {
		for _, tag := range ve.Tags {
			d := tagDomain(tag.Name)
			a, ok := m[d]
			if !ok {
				a = &acc{devices: make(map[string]bool)}
				m[d] = a
			}
			a.totalConf += float64(tag.Confidence) / 100.0
			a.count++
			a.devices[ve.DevicePubkeyHex] = true
		}
	}
	out := make([]DomainAggregate, 0, len(m))
	for domain, a := range m {
		avg := 0.0
		if a.count > 0 {
			avg = a.totalConf / float64(a.count)
		}
		out = append(out, DomainAggregate{
			Domain:        domain,
			TotalCount:    a.count,
			AvgConfidence: avg,
			UniqueDevices: len(a.devices),
		})
	}
	return out
}
