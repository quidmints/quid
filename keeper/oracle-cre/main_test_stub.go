//go:build !wasip1

// main_test_stub.go — Entry point stub for local test builds.
// Under wasip1, main.go provides the real entry point.
// For `go test` (which runs without wasip1 tag) we need a package main.
package main

func main() {}
