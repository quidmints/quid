//go:build wasip1

// http.go — HTTP adapter using the CRE SDK networking capability.
//
// All outbound HTTP calls in the oracle route through these three functions.
// Under CRE WASM, net/http has no socket support — the CRE SDK provides
// host-imported HTTP via crehttp.Do instead.

package main

import (
	"bytes"
	"fmt"
	"io"
	"strings"

	crehttp "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
)

func doHTTPPost(url string, contentType string, body []byte, headers map[string]string) ([]byte, error) {
	req := crehttp.Request{
		Method: "POST",
		URL:    url,
		Body:   body,
		Headers: map[string][]string{
			"Content-Type": {contentType},
		},
	}
	for k, v := range headers {
		req.Headers[k] = []string{v}
	}
	resp, err := crehttp.Do(req)
	if err != nil {
		return nil, fmt.Errorf("CRE HTTP POST %s: %w", url, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		preview, _ := io.ReadAll(io.LimitReader(bytes.NewReader(resp.Body), 256))
		return nil, fmt.Errorf("CRE HTTP POST %s: status %d: %s", url, resp.StatusCode, preview)
	}
	return resp.Body, nil
}

func doHTTPGet(url string, headers map[string]string) ([]byte, error) {
	req := crehttp.Request{
		Method:  "GET",
		URL:     url,
		Headers: map[string][]string{},
	}
	for k, v := range headers {
		req.Headers[k] = []string{v}
	}
	resp, err := crehttp.Do(req)
	if err != nil {
		return nil, fmt.Errorf("CRE HTTP GET %s: %w", url, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		preview, _ := io.ReadAll(io.LimitReader(bytes.NewReader(resp.Body), 256))
		return nil, fmt.Errorf("CRE HTTP GET %s: status %d: %s", url, resp.StatusCode, preview)
	}
	return resp.Body, nil
}

func doHTTPPostMultipart(url string, body []byte, contentType string, headers map[string]string) ([]byte, error) {
	if !strings.HasPrefix(contentType, "multipart/") {
		return nil, fmt.Errorf("doHTTPPostMultipart: expected multipart content-type, got %q", contentType)
	}
	return doHTTPPost(url, contentType, body, headers)
}
