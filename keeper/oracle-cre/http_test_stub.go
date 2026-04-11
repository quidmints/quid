//go:build !wasip1

// http_test_stub.go — net/http backend for local test builds.
//
// Under wasip1, http.go provides doHTTPPost/doHTTPGet via the CRE SDK.
// This file provides the same signatures using net/http so the oracle
// compiles and tests run locally without any CRE SDK dependency.
//
// All tests that exercise pure pipeline logic (deterministic resolve,
// evidence summary, encoding) do not make any HTTP calls, so this stub
// is never invoked during testing — it just satisfies the linker.

package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

var testHTTPClient = &http.Client{Timeout: 30 * time.Second}

func doHTTPPost(url string, contentType string, body []byte, headers map[string]string) ([]byte, error) {
	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", contentType)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := testHTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP POST %s: %w", url, err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP POST %s: status %d", url, resp.StatusCode)
	}
	return b, nil
}

func doHTTPGet(url string, headers map[string]string) ([]byte, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := testHTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP GET %s: status %d", url, resp.StatusCode)
	}
	return b, nil
}

func doHTTPPostMultipart(url string, body []byte, contentType string, headers map[string]string) ([]byte, error) {
	if !strings.HasPrefix(contentType, "multipart/") {
		return nil, fmt.Errorf("expected multipart content-type, got %q", contentType)
	}
	return doHTTPPost(url, contentType, body, headers)
}
