// tee_privacy.go — TEE key and attestation stubs for the CRE oracle.
//
// CRE trust is established by the WASM bytecode hash pinned in the workflow.
// No hardware attestation is performed at runtime.

package main

import (
	"crypto/aes"
	"crypto/cipher"
	"fmt"
	"log"
)

// TEEAttestation is the runtime attestation record.
// InitTEEKey and TEEPublicKeyHex are defined in privacy_bridge.go.
type TEEAttestation struct {
	PlatformData string `json:"platform_data"`
	OracleKey    string `json:"oracle_key"`
	Timestamp    int64  `json:"timestamp"`
	ClaimsHash   string `json:"claims_hash"`
}

func verifyPlatformAttestation(_ *TEEAttestation) error {
	log.Println("[tee] CRE WASM — attestation delegated to DON workflow bytecode hash")
	return nil
}

func isSEVSNP() bool { return false }

// decryptAES256CTR decrypts AES-256-CTR ciphertext.
// Format: first 16 bytes = IV/nonce, remainder = ciphertext.
func decryptAES256CTR(data, key []byte) ([]byte, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("decryptAES256CTR: key must be 32 bytes, got %d", len(key))
	}
	if len(data) < 16 {
		return nil, fmt.Errorf("decryptAES256CTR: ciphertext too short")
	}
	iv, ciphertext := data[:16], data[16:]
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("decryptAES256CTR: new cipher: %w", err)
	}
	out := make([]byte, len(ciphertext))
	cipher.NewCTR(block, iv).XORKeyStream(out, ciphertext)
	return out, nil
}
