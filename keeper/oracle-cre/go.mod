module github.com/safta/keeper/oracle-cre

go 1.22

require (
	github.com/smartcontractkit/cre-sdk-go v1.0.0
)

// Shared pipeline logic copied from svm/oracle — no shared module dependency.
// Evidence verification uses only stdlib crypto (ed25519, sha256).
// Privacy bridge uses only stdlib crypto (ecdsa, sha256).
