// storage.go — 0G Storage stub for the CRE oracle.
//
// Blobs are uploaded out-of-band before the workflow runs.
// Download is via the public 0G Storage HTTP gateway (ZG_GATEWAY_URL).

package main

import (
	"fmt"
	"os"
)

type ZeroGStorageClient interface {
	UploadBlob(ctx interface{}, data []byte, encryptionKey []byte) (string, error)
	DownloadBlob(ctx interface{}, rootHex string, encryptionKey []byte) ([]byte, error)
}

type ZeroGStorageClientImpl struct {
	GatewayURL string
}

func NewZeroGStorageClient(_, _, _ string) *ZeroGStorageClientImpl {
	gw := os.Getenv("ZG_GATEWAY_URL")
	if gw == "" {
		gw = "https://storage.0g.ai"
	}
	return &ZeroGStorageClientImpl{GatewayURL: gw}
}

func (c *ZeroGStorageClientImpl) UploadBlob(_ interface{}, _ []byte, _ []byte) (string, error) {
	return "", fmt.Errorf("ZeroGStorageClient.UploadBlob: upload out-of-band before workflow runs")
}

func (c *ZeroGStorageClientImpl) DownloadBlob(_ interface{}, rootHex string, encryptionKey []byte) ([]byte, error) {
	url := fmt.Sprintf("%s/download/%s", c.GatewayURL, rootHex)
	data, err := doHTTPGet(url, nil)
	if err != nil {
		return nil, fmt.Errorf("0G Storage download %s: %w", rootHex, err)
	}
	if len(encryptionKey) == 0 {
		return data, nil
	}
	return decryptAES256CTR(data, encryptionKey)
}
