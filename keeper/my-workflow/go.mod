module safta-cre/my-workflow

go 1.24.5

// Core SDK: use v1.0.0 (or latest compatible)
// Capability packages: use v1.0.0-beta.0
// Run `go mod tidy` after creating this file to resolve actual versions.
//
// If go mod tidy fails on versions, check:
//   go get github.com/smartcontractkit/cre-sdk-go@v1.0.0
//   go get github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm@v1.0.0-beta.0
//   go get github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http@v1.0.0-beta.0

require (
	github.com/ethereum/go-ethereum v1.16.4
	github.com/smartcontractkit/cre-sdk-go v1.0.0
	github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm v1.0.0-beta.0
	github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http v1.0.0-beta.0
)

require (
	github.com/davecgh/go-spew v1.1.2-0.20180830191138-d8f796af33cc // indirect
	github.com/decred/dcrd/dcrec/secp256k1/v4 v4.0.1 // indirect
	github.com/go-viper/mapstructure/v2 v2.4.0 // indirect
	github.com/holiman/uint256 v1.3.2 // indirect
	github.com/pmezard/go-difflib v1.0.1-0.20181226105442-5d4384ee4fb2 // indirect
	github.com/shopspring/decimal v1.4.0 // indirect
	github.com/smartcontractkit/chainlink-protos/cre/go v0.0.0-20250918131840-564fe2776a35 // indirect
	github.com/stretchr/testify v1.11.1 // indirect
	golang.org/x/crypto v0.36.0 // indirect
	golang.org/x/sys v0.36.0 // indirect
	google.golang.org/protobuf v1.36.7 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

// NOTE: This go.mod is a SKELETON. You MUST run `go mod tidy` to:
//   1. Resolve transitive dependencies
//   2. Generate go.sum
//   3. Fix any version incompatibilities
//
// If the cre-sdk-go version has been updated since this file was created,
// check: https://pkg.go.dev/github.com/smartcontractkit/cre-sdk-go
// Latest at time of writing: v1.3.0
