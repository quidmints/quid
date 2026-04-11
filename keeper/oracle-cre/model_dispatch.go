// model_dispatch.go — Model dispatch for the CRE oracle.
//
// Routes inference requests by URI scheme. Uses doHTTPPost/doHTTPGet (http.go)
// since net/http is unavailable under wasip1.
// switchboard: URIs are not supported — this is a separate DON network.

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"os"
	"strings"
)

func dispatchToModel(providerURI string, req ModelRequest) (*ModelResponse, error) {
	switch {
	case strings.HasPrefix(providerURI, "0g:"):
		return dispatchZeroG(providerURI[3:], req)
	case strings.HasPrefix(providerURI, "https://"):
		return dispatchHTTPS(providerURI, req)
	case strings.HasPrefix(providerURI, "switchboard:"):
		return nil, fmt.Errorf("switchboard: URI not available in CRE oracle; use 0g: or https:")
	default:
		return nil, fmt.Errorf("unknown provider URI scheme %q; expected 0g: or https://", providerURI)
	}
}

func zerogServiceURL(providerAddress string) (string, error) {
	upper := strings.ToUpper(strings.TrimPrefix(providerAddress, "0x"))
	envKey := "ZG_SERVICE_" + upper
	u := os.Getenv(envKey)
	if u == "" {
		return "", fmt.Errorf("0G provider URL not configured: set %s in workflow config", envKey)
	}
	return strings.TrimRight(u, "/"), nil
}

func dispatchZeroG(providerAddress string, req ModelRequest) (*ModelResponse, error) {
	base, err := zerogServiceURL(providerAddress)
	if err != nil {
		return nil, err
	}
	if req.StepType == StepTranscribe {
		return dispatchZeroGTranscribe(base, req)
	}
	return dispatchZeroGChat(base, req)
}

func dispatchZeroGChat(base string, req ModelRequest) (*ModelResponse, error) {
	inputJSON, err := json.Marshal(req.InputData)
	if err != nil {
		return nil, err
	}
	body, err := json.Marshal(map[string]interface{}{
		"model": "default",
		"messages": []map[string]string{
			{"role": "user", "content": string(inputJSON)},
		},
	})
	if err != nil {
		return nil, err
	}
	respBody, err := doHTTPPost(base+"/v1/chat/completions", "application/json", body, nil)
	if err != nil {
		return nil, fmt.Errorf("0G chat: %w", err)
	}
	var oai struct {
		Choices []struct {
			Message struct{ Content string } `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(respBody, &oai); err != nil {
		return nil, fmt.Errorf("0G chat parse: %w", err)
	}
	if len(oai.Choices) == 0 {
		return nil, fmt.Errorf("0G chat: empty choices")
	}
	var mr ModelResponse
	if err := json.Unmarshal([]byte(oai.Choices[0].Message.Content), &mr); err != nil {
		return &ModelResponse{Success: true, Transcript: oai.Choices[0].Message.Content}, nil
	}
	return &mr, nil
}

func dispatchZeroGTranscribe(base string, req ModelRequest) (*ModelResponse, error) {
	var audioBytes []byte
	if m, ok := req.InputData.(map[string][]byte); ok {
		audioBytes = m["audio"]
	}
	if len(audioBytes) == 0 {
		return nil, fmt.Errorf("0G transcribe: no audio bytes in request")
	}
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	part, err := w.CreateFormFile("file", "audio.wav")
	if err != nil {
		return nil, err
	}
	if _, err := part.Write(audioBytes); err != nil {
		return nil, err
	}
	_ = w.WriteField("model", "whisper-1")
	if req.Params.Language != "" {
		_ = w.WriteField("language", req.Params.Language)
	}
	w.Close()
	respBody, err := doHTTPPostMultipart(base+"/v1/audio/transcriptions", buf.Bytes(), w.FormDataContentType(), nil)
	if err != nil {
		return nil, fmt.Errorf("0G transcribe: %w", err)
	}
	var tr struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(respBody, &tr); err != nil {
		return nil, fmt.Errorf("0G transcribe parse: %w", err)
	}
	var matches []string
	for _, kw := range req.Params.Keywords {
		if strings.Contains(strings.ToLower(tr.Text), strings.ToLower(kw)) {
			matches = append(matches, kw)
		}
	}
	return &ModelResponse{Success: true, Transcript: tr.Text, KeywordMatches: matches}, nil
}

func dispatchHTTPS(url string, req ModelRequest) (*ModelResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	respBody, err := doHTTPPost(url, "application/json", body, nil)
	if err != nil {
		return nil, fmt.Errorf("model request failed: %w", err)
	}
	var mr ModelResponse
	if err := json.Unmarshal(respBody, &mr); err != nil {
		return nil, fmt.Errorf("model response parse: %w", err)
	}
	return &mr, nil
}
