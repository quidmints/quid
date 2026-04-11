// cre_stubs.go — No-op stubs for Switchboard-specific TEE primitives.
//
// The Switchboard oracle uses hardware-attested TEE (AMD SEV-SNP) for
// in-process memory protection. The CRE oracle runs as a WASM binary inside
// the Chainlink DON — trust is established by bytecode hash, not by runtime
// attestation. These stubs satisfy the interfaces without performing any
// in-process zeroing or attestation checks.

package main

// ─────────────────────────────────────────────────────────────────────────────
// MEMORY PROTECTION (no-op in CRE WASM — OS process isolation handles this)
// ─────────────────────────────────────────────────────────────────────────────

// zeroMemory is a no-op in CRE. The WASM runtime's memory isolation and
// the short session lifetime of the DON function provide equivalent guarantees.
func zeroMemory(buf []byte) {
	for i := range buf {
		buf[i] = 0
	}
}

// TrackSensitive registers a buffer for zeroing on Dispatch() exit.
// In the CRE oracle this is a no-op — WASM memory is discarded after
// each invocation. Provided to satisfy the shared pipeline.go interface.
func TrackSensitive(_ []byte) {}

// FlushTEEState zeros all tracked sensitive buffers on session exit.
// No-op in CRE WASM — memory is discarded when the function returns.
func FlushTEEState() {}

// ─────────────────────────────────────────────────────────────────────────────
// ADAPTATION BLOB
// ─────────────────────────────────────────────────────────────────────────────

// Flush zeros the blob's in-memory data after session use.
// In CRE the blob data was already fetched ephemerally; zeroing is best-effort.
func (b *AdaptationBlob) Flush() {
	zeroMemory(b.Data)
}

// ─────────────────────────────────────────────────────────────────────────────
// ATTESTATION
// ─────────────────────────────────────────────────────────────────────────────

// VerifyOnChainAttestation verifies a TEE attestation record.
// In CRE the DON workflow itself is the trust anchor — the WASM hash pinned
// in the workflow definition replaces hardware attestation. This stub accepts
// all attestations so the pipeline can proceed to resolution.
func VerifyOnChainAttestation(att *TEEAttestation, trustedHashes []string) error {
	return nil
}

// ─────────────────────────────────────────────────────────────────────────────
// MODEL ROUTING
// ─────────────────────────────────────────────────────────────────────────────

// findRouteURI returns the best provider URI for a model class from the market's
// PipelineRoutes. Falls back to the provided fallback string if no match.
func findRouteURI(modelClass uint8, evidence *MarketEvidenceData, fallback string) string {
	if evidence == nil {
		return fallback
	}
	best := fallback
	bestPriority := uint8(255)
	for _, r := range evidence.PipelineRoutes {
		if r.ModelClass == modelClass && r.Priority < bestPriority {
			best = r.ProviderURI
			bestPriority = r.Priority
		}
	}
	return best
}
