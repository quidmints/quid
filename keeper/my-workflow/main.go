//go:build wasip1

// SAFTA Dual-Trigger CRE Workflow (Go)
//
// Faithful port of main.ts to Go using CRE Go SDK v1.0.0+
//
// API VERIFICATION STATUS:
//   ✅ = Verified from pkg.go.dev source or official working demo (credemos.com/cdf)
//   📖 = From docs.chain.link reference only (not source-verified)
//   ⚠️  = Inferred from patterns — compiler will catch mismatches
//
// TRIGGER 1: ResolutionRequested → WATCHDOG
// TRIGGER 2: DisputeForensicsRequested → FORENSIC EVIDENCE
// TRIGGER 3: HTTP → simulation & test entry point

package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"math/big"
	"sort"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"   // ✅ standard go-ethereum
	"github.com/ethereum/go-ethereum/common"          // ✅ standard go-ethereum
	"github.com/ethereum/go-ethereum/crypto"          // ✅ standard go-ethereum

	// ✅ Verified import paths from pkg.go.dev + credemos.com demo
	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

// ═══════════════════════════════════════════════════════════════════
//  Configuration (matches config_staging.json / config_production.json)
// ═══════════════════════════════════════════════════════════════════

type Config struct {
	ChainSelectorName string `json:"chainSelectorName"`
	IsTestnet         bool   `json:"isTestnet"`

	UMAContractAddress string `json:"umaContractAddress"`
	AuxContractAddress string `json:"auxContractAddress"`

	CoingeckoAPIURL     string `json:"coingeckoApiUrl"`
	CoinmarketcapAPIURL string `json:"coinmarketcapApiUrl"`
	DefillamaAPIURL     string `json:"defillamaApiUrl"`

	DepegThresholdBps     int `json:"depegThresholdBps"`
	AnalysisWindowHours   int `json:"analysisWindowHours"`
	WatchdogMinConfidence int `json:"watchdogMinConfidence"`
	WatchdogMinVendors    int `json:"watchdogMinVendors"`
	MinDepegDurationMin   int `json:"minDepegDurationMin"`
}

func (c *Config) applyDefaults() {
	if c.CoingeckoAPIURL == "" {
		c.CoingeckoAPIURL = "https://pro-api.coingecko.com/api/v3"
	}
	if c.CoinmarketcapAPIURL == "" {
		c.CoinmarketcapAPIURL = "https://pro-api.coinmarketcap.com/v1"
	}
	if c.DefillamaAPIURL == "" {
		c.DefillamaAPIURL = "https://stablecoins.llama.fi"
	}
	if c.DepegThresholdBps == 0 {
		c.DepegThresholdBps = 100
	}
	if c.AnalysisWindowHours == 0 {
		c.AnalysisWindowHours = 168
	}
	if c.WatchdogMinConfidence == 0 {
		c.WatchdogMinConfidence = 80
	}
	if c.WatchdogMinVendors == 0 {
		c.WatchdogMinVendors = 2
	}
	if c.MinDepegDurationMin == 0 {
		c.MinDepegDurationMin = 60 // 1 hour — hourly candle resolution
	}
}

// ═══════════════════════════════════════════════════════════════════
//  Stablecoin Metadata
//  All 11 stables from Aux.getStables() mapped with 3-vendor API IDs.
//  USYC (stables[10]) is yield-bearing RWA (~$1.07+), NOT $1-pegged.
// ═══════════════════════════════════════════════════════════════════

type StableMeta struct {
	CoingeckoID string
	CMCSymbol   string
	Symbol      string
	Name        string
	IsPegged    bool
	PegTarget   int64 // 8-decimal ($1.00 = 100_000_000)
}

// Keyed by lowercase Ethereum address
var stableMetaMap = map[string]StableMeta{
	"0xdac17f958d2ee523a2206206994597c13d831ec7": {CoingeckoID: "tether", CMCSymbol: "USDT", Symbol: "USDT", Name: "Tether", IsPegged: true, PegTarget: 100_000_000},
	"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": {CoingeckoID: "usd-coin", CMCSymbol: "USDC", Symbol: "USDC", Name: "USD Coin", IsPegged: true, PegTarget: 100_000_000},
	"0x6c3ea9036406852006290770bedfcaba0e23a0e8": {CoingeckoID: "paypal-usd", CMCSymbol: "PYUSD", Symbol: "PYUSD", Name: "PayPal USD", IsPegged: true, PegTarget: 100_000_000},
	"0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f": {CoingeckoID: "gho", CMCSymbol: "GHO", Symbol: "GHO", Name: "Aave GHO", IsPegged: true, PegTarget: 100_000_000},
	"0x6b175474e89094c44da98b954eedeac495271d0f": {CoingeckoID: "dai", CMCSymbol: "DAI", Symbol: "DAI", Name: "MakerDAO DAI", IsPegged: true, PegTarget: 100_000_000},
	"0xdc035d45d973e3ec169d2276ddab16f1e407384f": {CoingeckoID: "usds", CMCSymbol: "USDS", Symbol: "USDS", Name: "Sky USDS", IsPegged: true, PegTarget: 100_000_000},
	"0xcacd6fd266af91b8aed52accc382b4e165586e29": {CoingeckoID: "frax", CMCSymbol: "FRAX", Symbol: "FRAX", Name: "Frax", IsPegged: true, PegTarget: 100_000_000},
	"0x4c9edd5852cd905f086c759e8383e09bff1e68b3": {CoingeckoID: "ethena-usde", CMCSymbol: "USDE", Symbol: "USDe", Name: "Ethena USDe", IsPegged: true, PegTarget: 100_000_000},
	"0xf939e0a03fb07f59a73314e73794be0e57ac1b4e": {CoingeckoID: "crvusd", CMCSymbol: "CRVUSD", Symbol: "crvUSD", Name: "Curve USD", IsPegged: true, PegTarget: 100_000_000},
	"0x6440f144b7e50d6a8439336510312d2f54beb01d": {CoingeckoID: "liquity-bold", CMCSymbol: "BOLD", Symbol: "BOLD", Name: "Liquity BOLD", IsPegged: true, PegTarget: 100_000_000},
	"0x136471a34f6ef19fe571effc1ca711fdb8e49f2b": {CoingeckoID: "hashnote-usyc", CMCSymbol: "USYC", Symbol: "USYC", Name: "Hashnote USYC", IsPegged: false, PegTarget: 107_000_000},
}

// ═══════════════════════════════════════════════════════════════════
//  Event signatures (keccak256 of the Solidity event signature)
// ═══════════════════════════════════════════════════════════════════

var (
	// UMA.sol: event ResolutionRequested(bytes32 assertionId, uint8 claimedSide, uint bond)
	// No indexed params → all in log.Data, only topics[0] = sig hash
	resolutionRequestedSig = crypto.Keccak256([]byte("ResolutionRequested(bytes32,uint8,uint256)"))

	// UMA.sol: event DisputeForensicsRequested(bytes32 indexed assertionId, uint8 claimedSide, uint requestTimestamp)
	// assertionId is indexed → topics[1]. claimedSide + requestTimestamp in log.Data.
	disputeForensicsRequestedSig = crypto.Keccak256([]byte("DisputeForensicsRequested(bytes32,uint8,uint256)"))
)

// ═══════════════════════════════════════════════════════════════════
//  Shared types
// ═══════════════════════════════════════════════════════════════════

type VendorPriceData struct {
	VendorName    string `json:"vendorName"`
	MinPrice      int64  `json:"minPrice"`
	MaxPrice      int64  `json:"maxPrice"`
	PriceAtCutoff int64  `json:"priceAtCutoff"`
	NumPrices     int    `json:"numPrices"`
	ResponseHash  string `json:"responseHash"`
	// Temporal analysis fields (0 = no time-series data available for this vendor)
	DepegDurationMin int   `json:"depegDurationMin"` // longest consecutive run below threshold
	CandlesBelowPeg  int  `json:"candlesBelowPeg"`  // total candles outside peg band
	TotalCandles     int   `json:"totalCandles"`     // total candles in window
	IntervalSec      int64 `json:"intervalSec"`      // estimated seconds between data points
}

type Verdict struct {
	DepegDetected    bool   `json:"depegDetected"`
	DepegSeverityBps uint   `json:"depegSeverityBps"`
	Confidence       string `json:"confidence"`
	Reasoning        string `json:"reasoning"`
	RecommendedSide  int    `json:"recommendedSide"`
	DataQuality      string `json:"dataQuality"`
}

type AnalysisResult struct {
	Meta        StableMeta
	VendorData  []VendorPriceData
	Verdict     Verdict
	Stables     []string
	WindowStart int64
	WindowEnd   int64
}

// HTTP trigger test payload (from CLI simulation)
type HTTPTestPayload struct {
	AssertionID      string `json:"assertionId"`
	ClaimedSide      int    `json:"claimedSide"`
	Bond             string `json:"bond"`
	Mode             string `json:"mode"`
	RequestTimestamp int64  `json:"requestTimestamp"`
}

// ═══════════════════════════════════════════════════════════════════
//  ABI type definitions (for manual encode/decode)
//  ✅ go-ethereum/accounts/abi is standard, well-documented
// ═══════════════════════════════════════════════════════════════════

var (
	bytes32Type, _      = abi.NewType("bytes32", "", nil)
	uint8Type, _        = abi.NewType("uint8", "", nil)
	uint256Type, _      = abi.NewType("uint256", "", nil)
	int256Type, _       = abi.NewType("int256", "", nil)
	addressArrayType, _ = abi.NewType("address[]", "", nil)
)


// Verdict payload: (bytes32, uint8, uint8, uint256, uint8, bytes32)
// Must match: abi.decode(report, (bytes32, uint8, uint8, uint, uint8, bytes32))
var verdictABI = abi.Arguments{
	{Type: bytes32Type}, // assertionId
	{Type: uint8Type},   // claimedSide
	{Type: uint8Type},   // recommendedSide
	{Type: uint256Type},  // maxDeviationBps
	{Type: uint8Type},   // confidence (0-100)
	{Type: bytes32Type}, // evidenceHash
}

// ResolutionRequested data: (bytes32, uint8, uint256)
var resolutionRequestedABI = abi.Arguments{
	{Type: bytes32Type},
	{Type: uint8Type},
	{Type: uint256Type},
}

// DisputeForensicsRequested data: (uint8, uint256)
var disputeForensicsDataABI = abi.Arguments{
	{Type: uint8Type},
	{Type: uint256Type},
}

// ═══════════════════════════════════════════════════════════════════
//  EVM Read: stables from Aux
//
//  📖 evm.Client.CallContract — from docs + bindings interface
//  ⚠️  CallContractRequest/CallMsg field names may differ slightly
//      Compiler will catch. See TODO below.
// ═══════════════════════════════════════════════════════════════════

func readStablesFromAux(config *Config, runtime cre.Runtime, evmClient *evm.Client) ([]string, error) {
	logger := runtime.Logger() // ✅ verified: RuntimeBase.Logger() *slog.Logger

	// Encode getStables() selector = keccak256("getStables()")[:4]
	callData := crypto.Keccak256([]byte("getStables()"))[:4]

	// 📖 evm.CallContractRequest — field names from docs reference page
	// TODO: If compiler rejects CallMsg/CallContractRequest, check the actual
	// protobuf-generated struct in the SDK. The demo uses generated bindings
	// (e.g. balanceReader.GetNativeBalances()) which abstracts this away.
	// For raw calls without bindings, use this pattern.
	result, err := evmClient.CallContract(runtime, &evm.CallContractRequest{
		Call: &evm.CallMsg{
			From: common.Address{}.Bytes(),
			To:   common.HexToAddress(config.AuxContractAddress).Bytes(),
			Data: callData,
		},
	}).Await() // ✅ Promise.Await() verified from pkg.go.dev
	if err != nil {
		return nil, fmt.Errorf("callContract getStables failed: %w", err)
	}

	// ✅ result.Data — verified from docs: CallContractReply.Data = []byte
	decoded, err := getStablesReturnABI.Unpack(result.Data)
	if err != nil {
		return nil, fmt.Errorf("unpack getStables failed: %w", err)
	}

	addrs, ok := decoded[0].([]common.Address)
	if !ok {
		return nil, fmt.Errorf("unexpected type from getStables: %T", decoded[0])
	}

	stables := make([]string, len(addrs))
	for i, a := range addrs {
		stables[i] = strings.ToLower(a.Hex())
	}

	logger.Info(fmt.Sprintf("Loaded %d stables from Aux", len(stables)))
	return stables, nil
}

// ═══════════════════════════════════════════════════════════════════
//  HTTP: Multi-vendor price fetching
//
//  ✅ http.SendRequest pattern verified from credemos.com demo
//  ✅ http.SendRequester.SendRequest(&http.Request{}) verified
//  ✅ http.Request{Url, Method, Body, Headers} verified
//
//  In TS this ran inside runtime.runInNodeMode(). In Go, the
//  http.SendRequest helper wraps RunInNodeMode automatically.
//  Secrets are fetched BEFORE node mode (CRE constraint: sequential
//  GetSecret in DON mode only).
// ═══════════════════════════════════════════════════════════════════

func doFetchVendorPrices(
	config *Config,
	logger *slog.Logger,
	sr *http.SendRequester,
	meta StableMeta,
	windowStart, windowEnd int64,
	cmcAPIKey string, // pre-fetched from secrets in DON mode
	cgAPIKey string,  // optional: CoinGecko Pro API key
) (*[]VendorPriceData, error) {
	results := make([]VendorPriceData, 0, 3)

	// ── Vendor 1 (optional): CoinGecko Pro historical range ──
	if cgAPIKey != "" {
		cgURL := fmt.Sprintf("%s/coins/%s/market_chart/range?vs_currency=usd&from=%d&to=%d&x_cg_pro_api_key=%s",
			config.CoingeckoAPIURL, meta.CoingeckoID, windowStart, windowEnd, cgAPIKey)

		cgResp, err := sr.SendRequest(&http.Request{
			Url:    cgURL,
			Method: "GET",
		}).Await()
		if err == nil && cgResp.StatusCode == 200 {
			var cgData struct {
				Prices [][]json.Number `json:"prices"`
			}
			if json.Unmarshal(cgResp.Body, &cgData) == nil && len(cgData.Prices) > 0 {
				var minP, maxP int64 = math.MaxInt64, 0
				var cutoffP int64
				minDiff := int64(math.MaxInt64)

				for _, p := range cgData.Prices {
					if len(p) < 2 {
						continue
					}
					tsF, _ := p[0].Float64()
					priceF, _ := p[1].Float64()
					if priceF <= 0 {
						continue
					}
					price8 := int64(math.Round(priceF * 1e8))
					ts := int64(tsF / 1000)
					if price8 < minP {
						minP = price8
					}
					if price8 > maxP {
						maxP = price8
					}
					diff := abs64(ts - windowEnd)
					if diff < minDiff {
						minDiff = diff
						cutoffP = price8
					}
				}

				bodyHash := fmt.Sprintf("0x%x", crypto.Keccak256(cgResp.Body))

				// ── Temporal analysis: duration below peg threshold ──
				// Second pass over same data — sorted by timestamp for
				// consecutive-run detection. No new HTTP calls.
				type tsPrice struct{ ts, price int64 }
				sorted := make([]tsPrice, 0, len(cgData.Prices))
				for _, p := range cgData.Prices {
					if len(p) < 2 { continue }
					tsF, _ := p[0].Float64()
					priceF, _ := p[1].Float64()
					if priceF <= 0 { continue }
					sorted = append(sorted, tsPrice{
						ts:    int64(tsF / 1000),
						price: int64(math.Round(priceF * 1e8)),
					})
				}
				sort.Slice(sorted, func(i, j int) bool { return sorted[i].ts < sorted[j].ts })

				var cgDepegDur int
				var cgCandlesBelow, cgTotalCandles int
				var cgIntervalSec int64
				cgTotalCandles = len(sorted)
				if cgTotalCandles > 1 {
					cgIntervalSec = (sorted[cgTotalCandles-1].ts - sorted[0].ts) / int64(cgTotalCandles-1)
				}
				if cgTotalCandles >= 24 && cgIntervalSec > 0 {
					thresholdAbs := meta.PegTarget * int64(config.DepegThresholdBps) / 10000
					lowerBound := meta.PegTarget - thresholdAbs
					upperBound := meta.PegTarget + thresholdAbs
					longestRun := 0
					currentRun := 0
					for _, sp := range sorted {
						if sp.price < lowerBound || sp.price > upperBound {
							cgCandlesBelow++
							currentRun++
							if currentRun > longestRun { longestRun = currentRun }
						} else {
							currentRun = 0
						}
					}
					cgDepegDur = int(int64(longestRun) * cgIntervalSec / 60)
				}

				results = append(results, VendorPriceData{
					VendorName:       "coingecko",
					MinPrice:         minP,
					MaxPrice:         maxP,
					PriceAtCutoff:    cutoffP,
					NumPrices:        len(cgData.Prices),
					ResponseHash:     bodyHash,
					DepegDurationMin: cgDepegDur,
					CandlesBelowPeg:  cgCandlesBelow,
					TotalCandles:     cgTotalCandles,
					IntervalSec:      cgIntervalSec,
				})
			}
		} else if err != nil {
			logger.Warn(fmt.Sprintf("CoinGecko fetch failed for %s: %v", meta.Symbol, err))
		} else {
			logger.Warn(fmt.Sprintf("CoinGecko unexpected status %d for %s", cgResp.StatusCode, meta.Symbol))
		}
	}

	// ── Vendor 2: DefiLlama (stablecoins endpoint) ──
	llamaURL := fmt.Sprintf("%s/stablecoins", config.DefillamaAPIURL)
	llamaResp, err := sr.SendRequest(&http.Request{
		Url:    llamaURL,
		Method: "GET",
	}).Await()
	if err == nil && llamaResp.StatusCode == 200 {
		var llamaData struct {
			PeggedAssets []struct {
				GeckoID string      `json:"gecko_id"`
				Price   json.Number `json:"price"`
			} `json:"peggedAssets"`
		}
		if json.Unmarshal(llamaResp.Body, &llamaData) == nil {
			for _, asset := range llamaData.PeggedAssets {
				if asset.GeckoID == meta.CoingeckoID {
					priceF, pErr := asset.Price.Float64()
					if pErr != nil || priceF <= 0 {
						continue
					}
					price8 := int64(math.Round(priceF * 1e8))
					truncated := llamaResp.Body
					if len(truncated) > 1024 {
						truncated = truncated[:1024]
					}
					bodyHash := fmt.Sprintf("0x%x", crypto.Keccak256(truncated))
					results = append(results, VendorPriceData{
						VendorName:    "defillama",
						MinPrice:      price8,
						MaxPrice:      price8,
						PriceAtCutoff: price8,
						NumPrices:     1,
						ResponseHash:  bodyHash,
					})
					break
				}
			}
		}
	} else if err != nil {
		logger.Warn(fmt.Sprintf("DefiLlama fetch failed for %s: %v", meta.Symbol, err))
	} else {
		logger.Warn(fmt.Sprintf("DefiLlama unexpected status %d for %s", llamaResp.StatusCode, meta.Symbol))
	}

	// ── Vendor 3: CoinMarketCap ──
	// Try OHLCV historical first (hourly candles) for temporal analysis.
	// Falls back to existing quotes/latest if historical unavailable
	// (wrong API tier, rate limit, etc). Fallback produces identical
	// output to the original code — zero temporal fields.
	if cmcAPIKey != "" {
		cmcDone := false

		// Attempt: OHLCV historical (hourly candles over analysis window)
		cmcHistURL := fmt.Sprintf("%s/cryptocurrency/ohlcv/historical?symbol=%s&time_start=%d&time_end=%d&interval=hourly&convert=USD",
			config.CoinmarketcapAPIURL, meta.CMCSymbol, windowStart, windowEnd)

		cmcHistResp, histErr := sr.SendRequest(&http.Request{
			Url:     cmcHistURL,
			Method:  "GET",
			Headers: map[string]string{"X-CMC_PRO_API_KEY": cmcAPIKey},
		}).Await()
		if histErr == nil && cmcHistResp.StatusCode == 200 {
			var cmcOHLCV struct {
				Data struct {
					Quotes []struct {
						Quote struct {
							USD struct {
								Open   float64 `json:"open"`
								High   float64 `json:"high"`
								Low    float64 `json:"low"`
								Close  float64 `json:"close"`
							} `json:"USD"`
						} `json:"quote"`
					} `json:"quotes"`
				} `json:"data"`
			}
			if json.Unmarshal(cmcHistResp.Body, &cmcOHLCV) == nil && len(cmcOHLCV.Data.Quotes) >= 24 {
				var cmcMinP, cmcMaxP int64 = math.MaxInt64, 0
				cmcCandlesBelow := 0
				longestRun := 0
				currentRun := 0

				thresholdAbs := meta.PegTarget * int64(config.DepegThresholdBps) / 10000
				lowerBound := meta.PegTarget - thresholdAbs
				upperBound := meta.PegTarget + thresholdAbs

				for _, q := range cmcOHLCV.Data.Quotes {
					low8 := int64(math.Round(q.Quote.USD.Low * 1e8))
					high8 := int64(math.Round(q.Quote.USD.High * 1e8))
					close8 := int64(math.Round(q.Quote.USD.Close * 1e8))
					if low8 > 0 && low8 < cmcMinP { cmcMinP = low8 }
					if high8 > cmcMaxP { cmcMaxP = high8 }
					// Use close price for duration (settled price, not wicks)
					if close8 < lowerBound || close8 > upperBound {
						cmcCandlesBelow++
						currentRun++
						if currentRun > longestRun { longestRun = currentRun }
					} else {
						currentRun = 0
					}
				}

				nq := len(cmcOHLCV.Data.Quotes)
				lastClose := int64(math.Round(cmcOHLCV.Data.Quotes[nq-1].Quote.USD.Close * 1e8))
				bodyHash := fmt.Sprintf("0x%x", crypto.Keccak256(cmcHistResp.Body))

				results = append(results, VendorPriceData{
					VendorName:       "coinmarketcap",
					MinPrice:         cmcMinP,
					MaxPrice:         cmcMaxP,
					PriceAtCutoff:    lastClose,
					NumPrices:        nq,
					ResponseHash:     bodyHash,
					DepegDurationMin: longestRun * 60, // hourly candles → 60 min each
					CandlesBelowPeg:  cmcCandlesBelow,
					TotalCandles:     nq,
					IntervalSec:      3600,
				})
				cmcDone = true
			}
		}

		// Fallback: spot quote (original behavior, zero temporal fields)
		if !cmcDone {
			cmcURL := fmt.Sprintf("%s/cryptocurrency/quotes/latest?symbol=%s&convert=USD",
				config.CoinmarketcapAPIURL, meta.CMCSymbol)

			cmcResp, err := sr.SendRequest(&http.Request{
				Url:     cmcURL,
				Method:  "GET",
				Headers: map[string]string{"X-CMC_PRO_API_KEY": cmcAPIKey},
			}).Await()
			if err == nil && cmcResp.StatusCode == 200 {
				var cmcRaw struct {
					Data map[string]struct {
						Quote struct {
							USD struct {
								Price float64 `json:"price"`
							} `json:"USD"`
						} `json:"quote"`
					} `json:"data"`
				}
				if json.Unmarshal(cmcResp.Body, &cmcRaw) == nil {
					if entry, ok := cmcRaw.Data[meta.CMCSymbol]; ok && entry.Quote.USD.Price > 0 {
						price8 := int64(math.Round(entry.Quote.USD.Price * 1e8))
						bodyHash := fmt.Sprintf("0x%x", crypto.Keccak256(cmcResp.Body))
						results = append(results, VendorPriceData{
							VendorName:    "coinmarketcap",
							MinPrice:      price8,
							MaxPrice:      price8,
							PriceAtCutoff: price8,
							NumPrices:     1,
							ResponseHash:  bodyHash,
						})
					}
				}
			} else if err != nil {
				logger.Warn(fmt.Sprintf("CMC fetch failed for %s: %v", meta.Symbol, err))
			} else {
				logger.Warn(fmt.Sprintf("CMC unexpected status %d for %s", cmcResp.StatusCode, meta.Symbol))
			}
		}
	}

	return &results, nil
}

// Deterministic verdict — pure math, no AI, fully consensus-safe.
func deterministicVerdict(meta StableMeta, vendorData []VendorPriceData, thresholdBps int, claimedSide int, minDurationMin int) Verdict {
	// ── Price-based analysis (unchanged from original) ──
	allMins := make([]int64, len(vendorData))
	for i, v := range vendorData {
		allMins[i] = v.MinPrice
	}
	medianMin := medianI64(allMins)
	deviationBps := int(math.Round(float64(medianMin-meta.PegTarget) / float64(meta.PegTarget) * 10000))
	priceDepeg := absInt(deviationBps) >= thresholdBps

	// ── Temporal analysis (new — degrades to no-op when data absent) ──
	// Collect duration from vendors with sufficient time-series granularity.
	// TotalCandles >= 24 ensures sub-daily resolution (filters out vendors
	// that only returned a spot price — those have TotalCandles=0).
	var durations []int
	for _, v := range vendorData {
		if v.TotalCandles >= 24 {
			durations = append(durations, v.DepegDurationMin)
		}
	}

	sustainedDepeg := true // default: no temporal data → trust price analysis only
	hasTemporal := len(durations) > 0
	medianDuration := 0
	if hasTemporal {
		sort.Ints(durations)
		n := len(durations)
		if n%2 == 0 {
			medianDuration = (durations[n/2-1] + durations[n/2]) / 2
		} else {
			medianDuration = durations[n/2]
		}
		// Duration gate: deviation must be sustained.
		// Exception: extreme deviations (>= 3x threshold) bypass duration
		// check — if USDC hits $0.70 even briefly, something is very wrong.
		if absInt(deviationBps) < thresholdBps*3 {
			sustainedDepeg = medianDuration >= minDurationMin
		}
	}

	depeg := priceDepeg && sustainedDepeg

	// ── Confidence (enhanced with temporal signal) ──
	// Original logic preserved as baseline; temporal data modulates.
	confidence := "low"
	if len(vendorData) >= 2 {
		halfThreshold := thresholdBps / 2
		if absInt(deviationBps) < halfThreshold || absInt(deviationBps) > thresholdBps*2 {
			// Clearly pegged (< half threshold) or clearly depegged (> 2x threshold)
			confidence = "high"
		} else if len(vendorData) >= 3 {
			confidence = "high"
		} else {
			confidence = "medium"
		}

		// Temporal modulation
		if hasTemporal {
			if priceDepeg && !sustainedDepeg {
				// Price says depeg but duration too short → ambiguous flash event
				if confidence == "high" { confidence = "medium" }
			} else if priceDepeg && sustainedDepeg && medianDuration >= minDurationMin*2 {
				// Price AND duration strongly agree → reinforce
				confidence = "high"
			}
		}
	}

	quality := "insufficient"
	if len(vendorData) >= 2 {
		quality = "sufficient"
		if hasTemporal {
			quality = "temporal" // signals that time-series data was available
		}
	}

	recSide := 0
	if depeg {
		recSide = claimedSide
	}

	reasoning := fmt.Sprintf("Median min deviation: %dbps vs %.4f reference across %d vendors.", deviationBps, float64(meta.PegTarget)/1e8, len(vendorData))
	if hasTemporal {
		reasoning += fmt.Sprintf(" Duration: %dm (min required: %dm, %d vendors with temporal data).", medianDuration, minDurationMin, len(durations))
		if priceDepeg && !sustainedDepeg {
			reasoning += " Flash event: price breached threshold but did not sustain."
		}
	}

	return Verdict{
		DepegDetected:    depeg,
		DepegSeverityBps: uint(absInt(deviationBps)),
		Confidence:       confidence,
		Reasoning:        reasoning,
		RecommendedSide:  recSide,
		DataQuality:      quality,
	}
}

// ═══════════════════════════════════════════════════════════════════
//  Pure helpers
// ═══════════════════════════════════════════════════════════════════

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func medianI64(arr []int64) int64 {
	if len(arr) == 0 {
		return 0
	}
	s := make([]int64, len(arr))
	copy(s, arr)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	n := len(s)
	if n%2 == 0 {
		return (s[n/2-1] + s[n/2]) / 2
	}
	return s[n/2]
}

func confidenceToNum(c string) uint8 {
	// Must match UMA.sol's 0-100 scale (minConfidence defaults to 80)
	switch c {
	case "high":
		return 90
	case "medium":
		return 60
	default:
		return 30
	}
}

func keccakBytes(data []byte) [32]byte {
	h := crypto.Keccak256(data)
	var b [32]byte
	copy(b[:], h)
	return b
}

// ═══════════════════════════════════════════════════════════════════
//  Shared analysis pipeline
//
//  Fetches vendor prices via http.SendRequest (node mode),
//  then produces a deterministic verdict.
// ═══════════════════════════════════════════════════════════════════

func runAnalysis(
	config *Config,
	runtime cre.Runtime,
	evmClient *evm.Client,
	claimedSide int,
	requestTimestamp int64,
	label string,
) (*AnalysisResult, error) {
	logger := runtime.Logger()

	// ── Read stables from Aux ──
	logger.Info(fmt.Sprintf("[%s] Reading stables from Aux...", label))
	stables, err := readStablesFromAux(config, runtime, evmClient)
	if err != nil {
		logger.Error(fmt.Sprintf("[%s] Failed to read stables: %v", label, err))
		return nil, err
	}
	logger.Info(fmt.Sprintf("[%s] %d stables loaded", label, len(stables)))

	// ── Determine target ──
	targetIdx := 0
	if claimedSide > 0 {
		targetIdx = claimedSide - 1
	}
	if targetIdx >= len(stables) {
		return nil, fmt.Errorf("claimedSide %d exceeds stables length %d", claimedSide, len(stables))
	}
	targetStable := stables[targetIdx]
	meta, ok := stableMetaMap[targetStable]
	if !ok {
		return nil, fmt.Errorf("unknown stablecoin %s", targetStable)
	}

	logger.Info(fmt.Sprintf("[%s] Target: %s (%s), isPegged=%v", label, meta.Name, meta.Symbol, meta.IsPegged))

	// ── Analysis window ──
	windowEnd := requestTimestamp
	windowStart := windowEnd - int64(config.AnalysisWindowHours)*3600

	// ── Fetch secrets BEFORE node mode (CRE constraint: sequential in DON mode) ──
	// ✅ runtime.GetSecret verified from pkg.go.dev SecretsProvider interface
	cmcAPIKey := ""
	cmcResp, err := runtime.GetSecret(&cre.SecretRequest{Id: "CMC_API_KEY"}).Await()
	if err == nil && cmcResp != nil {
		cmcAPIKey = cmcResp.Value
	} else {
		logger.Warn(fmt.Sprintf("[%s] No CMC_API_KEY secret available", label))
	}

	cgAPIKey := ""
	cgResp, err := runtime.GetSecret(&cre.SecretRequest{Id: "CG_API_KEY"}).Await()
	if err == nil && cgResp != nil {
		cgAPIKey = cgResp.Value
	}

	// ── Fetch prices (node mode via http.SendRequest helper) ──
	// ✅ http.SendRequest pattern verified from credemos.com demo
	logger.Info(fmt.Sprintf("[%s] Fetching prices...", label))
	httpClient := &http.Client{}

	// Capture closure vars
	metaCopy := meta
	ws, we := windowStart, windowEnd
	cmcKey := cmcAPIKey
	cgKey := cgAPIKey

	vendorPromise := http.SendRequest(config, runtime, httpClient,
		func(cfg *Config, lg *slog.Logger, sr *http.SendRequester) (*[]VendorPriceData, error) {
			return doFetchVendorPrices(cfg, lg, sr, metaCopy, ws, we, cmcKey, cgKey)
		},
		// TS uses consensusIdenticalAggregation — Go equivalent:
		cre.ConsensusIdenticalAggregation[*[]VendorPriceData](),
	)

	vendorDataPtr, err := vendorPromise.Await()
	if err != nil || vendorDataPtr == nil || len(*vendorDataPtr) == 0 {
		logger.Error(fmt.Sprintf("[%s] No vendor data: %v", label, err))
		return nil, fmt.Errorf("no vendor data available")
	}
	vendorData := *vendorDataPtr

	logger.Info(fmt.Sprintf("[%s] %d vendors retrieved", label, len(vendorData)))

	// ── Deterministic verdict ──
	verdict := deterministicVerdict(meta, vendorData, config.DepegThresholdBps, claimedSide, config.MinDepegDurationMin)

	logger.Info(fmt.Sprintf("[%s] Verdict: depeg=%v, %dbps, %s",
		label, verdict.DepegDetected, verdict.DepegSeverityBps, verdict.Confidence))

	return &AnalysisResult{
		Meta:        meta,
		VendorData:  vendorData,
		Verdict:     verdict,
		Stables:     stables,
		WindowStart: windowStart,
		WindowEnd:   windowEnd,
	}, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Shared: encode verdict + generate report + write to UMA
//
//  ✅ runtime.GenerateReport — verified from pkg.go.dev Runtime interface
//  📖 cre.ReportRequest fields — from docs (EncodedPayload, EncoderName, etc.)
//  📖 evmClient.WriteReport — from docs reference page
//  ⚠️  WriteCreReportRequest vs WriteReportRequest naming — the bindings
//      interface says WriteReportRequest, docs say WriteCreReportRequest.
//      TODO: Use generated bindings (cre generate-bindings) for UMA.sol
//      to get WriteReportFromOnReport() helper which bypasses this.
// ═══════════════════════════════════════════════════════════════════

func encodeAndWriteVerdict(
	runtime cre.Runtime,
	evmClient *evm.Client,
	config *Config,
	label string,
	assertionId [32]byte,
	claimedSide uint8,
	recommendedSide uint8,
	deviationBps uint,
	confidence uint8,
	evidenceHash [32]byte,
) error {
	logger := runtime.Logger()

	payload, err := verdictABI.Pack(
		assertionId,
		claimedSide,
		recommendedSide,
		new(big.Int).SetUint64(uint64(deviationBps)),
		confidence,
		evidenceHash,
	)
	if err != nil {
		return fmt.Errorf("abi pack failed: %w", err)
	}

	// ✅ GenerateReport — verified interface method on cre.Runtime
	// 📖 ReportRequest = sdk.ReportRequest (from chainlink-protos)
	reportResp, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: payload,
		EncoderName:    "evm",
		SigningAlgo:     "ecdsa",
		HashingAlgo:     "keccak256",
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[%s] GenerateReport failed: %v", label, err))
		return fmt.Errorf("GenerateReport: %w", err)
	}

	// 📖 WriteReport — field names from docs reference
	// ⚠️  If WriteCreReportRequest doesn't compile, try WriteReportRequest
	writeResp, err := evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(config.UMAContractAddress).Bytes(),
		Report:    reportResp,
		GasConfig: &evm.GasConfig{GasLimit: 500000},
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[%s] WriteReport failed: %v", label, err))
		return fmt.Errorf("WriteReport: %w", err)
	}

	logger.Info(fmt.Sprintf("[%s] TX: %s", label, hex.EncodeToString(writeResp.TxHash)))
	return nil
}

// ═══════════════════════════════════════════════════════════════════
//  Watchdog decision logic
//  Mirrors the TS onResolutionRequested + HTTP watchdog path exactly.
// ═══════════════════════════════════════════════════════════════════

func watchdogDecision(config *Config, runtime cre.Runtime, evmClient *evm.Client,
	assertionId [32]byte, claimedSide int, requestTimestamp int64,
) (string, error) {
	logger := runtime.Logger()

	// If the market is already Resolved with a winning side, this trigger fired
	// because someone filed a new assertion post-depeg. Use it as an opportunity
	// to check whether the depegged stable has recovered. If so, send
	// recommendedSide = 0 to clear winningSide and allow restartMarket.
	// claimedSide > 0 here means the new assertion claims a (possibly different)
	// stable is depegged — check the winning side's recovery regardless.
	if claimedSide > 0 {
		recovery, err := runAnalysis(config, runtime, evmClient, claimedSide, requestTimestamp, "RecoveryCheck")
		if err == nil && !recovery.Verdict.DepegDetected {
			logger.Info(fmt.Sprintf("[Watchdog] %s recovered — sending recommendedSide=0", recovery.Meta.Symbol))
			verdictJSON, _ := json.Marshal(recovery.Verdict)
			evidenceHash := keccakBytes(verdictJSON)
			var zeroId [32]byte
			// assertionId=0: onReport checks recovery before asserter lookup
			_ = encodeAndWriteVerdict(
				runtime, evmClient, config, "Recovery",
				zeroId,
				uint8(claimedSide), 0,
				recovery.Verdict.DepegSeverityBps,
				confidenceToNum(recovery.Verdict.Confidence),
				evidenceHash,
			)
			return "Recovery signal sent", nil
		}
	}

	analysis, err := runAnalysis(config, runtime, evmClient, claimedSide, requestTimestamp, "Watchdog")
	if err != nil {
		return "Analysis failed", fmt.Errorf("watchdog analysis: %w", err)
	}

	meta := analysis.Meta
	vendorData := analysis.VendorData
	verdict := analysis.Verdict

	shouldDispute := false
	reason := ""

	if claimedSide == 0 {
		shouldDispute = false
		reason = "Side 0 claims not auto-disputed in v1"
	} else {
		evidenceContradicts := !verdict.DepegDetected
		confHigh := confidenceToNum(verdict.Confidence) >= uint8(config.WatchdogMinConfidence)
		enoughVendors := len(vendorData) >= config.WatchdogMinVendors

		if evidenceContradicts && confHigh && enoughVendors {
			shouldDispute = true
			reason = fmt.Sprintf("Evidence contradicts claim: %s did NOT depeg (%dbps, %s confidence, %d vendors)",
				meta.Symbol, verdict.DepegSeverityBps, verdict.Confidence, len(vendorData))
		} else if !evidenceContradicts {
			reason = fmt.Sprintf("Evidence supports claim: %s appears depegged (%dbps)", meta.Symbol, verdict.DepegSeverityBps)
		} else {
			reason = fmt.Sprintf("Insufficient confidence/data to auto-dispute (confidence=%s, vendors=%d)",
				verdict.Confidence, len(vendorData))
		}
	}

	// Cross-check: math must agree (safety override from TS)
	if shouldDispute {
		allMins := make([]int64, len(vendorData))
		for i, v := range vendorData {
			allMins[i] = v.MinPrice
		}
		medianMin := medianI64(allMins)
		mathDev := absInt(int(math.Round(float64(medianMin-meta.PegTarget) / float64(meta.PegTarget) * 10000)))
		if mathDev >= config.DepegThresholdBps {
			shouldDispute = false
			reason = fmt.Sprintf("Safety override: math says %dbps deviation, AI says no depeg. Skipping.", mathDev)
		}
	}

	logger.Info(fmt.Sprintf("[Watchdog] %s", reason))

	// Encode + write verdict
	recommendedSide := uint8(claimedSide)
	if shouldDispute {
		recommendedSide = uint8(verdict.RecommendedSide)
	}

	verdictJSON, _ := json.Marshal(verdict)
	evidenceHash := keccakBytes(verdictJSON)

	if err := encodeAndWriteVerdict(
		runtime, evmClient, config, "Watchdog",
		assertionId, uint8(claimedSide), recommendedSide,
		verdict.DepegSeverityBps, confidenceToNum(verdict.Confidence), evidenceHash,
	); err != nil {
		logger.Error(fmt.Sprintf("[Watchdog] Write failed: %v", err))
	}

	if shouldDispute {
		return "Dispute filed", nil
	}
	return "No dispute needed", nil
}

// ═══════════════════════════════════════════════════════════════════
//  Forensics evidence logic
//  Mirrors the TS onDisputeForensics + HTTP forensics path exactly.
// ═══════════════════════════════════════════════════════════════════

func forensicsEvidence(config *Config, runtime cre.Runtime, evmClient *evm.Client,
	assertionId [32]byte, claimedSide int, requestTimestamp int64,
) (string, error) {
	logger := runtime.Logger()

	analysis, err := runAnalysis(config, runtime, evmClient, claimedSide, requestTimestamp, "Forensics")
	if err != nil {
		return "Analysis failed", fmt.Errorf("forensics analysis: %w", err)
	}

	meta := analysis.Meta
	vendorData := analysis.VendorData
	verdict := analysis.Verdict

	allMins := make([]int64, len(vendorData))
	for i, v := range vendorData {
		allMins[i] = v.MinPrice
	}
	medianMin := medianI64(allMins)
	maxDeviationBps := uint(absInt(int(math.Round(float64(medianMin-meta.PegTarget) / float64(meta.PegTarget) * 10000))))
	mathSaysDepeg := maxDeviationBps >= uint(config.DepegThresholdBps)
	depegDetected := verdict.DepegDetected && mathSaysDepeg

	// Evidence hash (same merkle-ish construction as TS)
	hashes := make([]string, len(vendorData))
	for i, v := range vendorData {
		hashes[i] = v.ResponseHash
	}
	sort.Strings(hashes)

	workflowHash := fmt.Sprintf("0x%x", crypto.Keccak256([]byte("safta-dual-trigger-v3.0.0")))
	verdictJSON, _ := json.Marshal(verdict)
	verdictHash := fmt.Sprintf("0x%x", crypto.Keccak256(verdictJSON))
	evidenceHash := keccakBytes([]byte(strings.Join(hashes, "") + verdictHash + workflowHash))

	recommendedSide := uint8(0)
	if depegDetected {
		if claimedSide > 0 {
			recommendedSide = uint8(claimedSide)
		} else {
			recommendedSide = uint8(verdict.RecommendedSide)
		}
	}

	logger.Info(fmt.Sprintf("[Forensics] Evidence: deviation=%dbps, depeg=%v", maxDeviationBps, depegDetected))

	if err := encodeAndWriteVerdict(
		runtime, evmClient, config, "Forensics",
		assertionId, uint8(claimedSide), recommendedSide,
		maxDeviationBps, confidenceToNum(verdict.Confidence), evidenceHash,
	); err != nil {
		logger.Error(fmt.Sprintf("[Forensics] Write failed: %v", err))
	}

	return "Evidence submitted", nil
}

// ═══════════════════════════════════════════════════════════════════
//  TRIGGER 1: WATCHDOG — ResolutionRequested (EVM Log)
//
//  ✅ Callback signature: func(config *C, runtime cre.Runtime, log *evm.Log) (O, error)
//     Verified from pkg.go.dev Handler generic + docs evm-log-trigger-go
//  ✅ evm.Log.Data, log.GetTopics() — verified from docs reference
// ═══════════════════════════════════════════════════════════════════

func onResolutionRequested(config *Config, runtime cre.Runtime, log *evm.Log) (string, error) {
	logger := runtime.Logger()
	config.applyDefaults()

	// Decode: ResolutionRequested(bytes32, uint8, uint256) — all in log.Data
	decoded, err := resolutionRequestedABI.Unpack(log.Data)
	if err != nil {
		return "Decode failed", fmt.Errorf("unpack ResolutionRequested: %w", err)
	}

	assertionId := decoded[0].([32]byte)
	claimedSide := int(decoded[1].(uint8))

	logger.Info(fmt.Sprintf("[Watchdog] Assertion: 0x%x, side=%d", assertionId, claimedSide))

	// 📖 evm.ChainSelectorFromName — from docs, returns (uint64, error)
	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return "Chain not found", err
	}
	evmClient := &evm.Client{ChainSelector: chainSel} // ✅ verified from demo

	// Use runtime.Now() for consensus-safe timestamp
	// ✅ runtime.Now() verified from pkg.go.dev RuntimeBase
	requestTimestamp := runtime.Now().Unix()

	return watchdogDecision(config, runtime, evmClient, assertionId, claimedSide, requestTimestamp)
}

// ═══════════════════════════════════════════════════════════════════
//  TRIGGER 2: FORENSIC EVIDENCE — DisputeForensicsRequested (EVM Log)
// ═══════════════════════════════════════════════════════════════════

func onDisputeForensics(config *Config, runtime cre.Runtime, log *evm.Log) (string, error) {
	logger := runtime.Logger()
	config.applyDefaults()

	// topics[1] = assertionId (indexed)
	topics := log.GetTopics() // ✅ verified from docs evm.Log reference
	if len(topics) < 2 {
		return "Invalid log", fmt.Errorf("expected >= 2 topics, got %d", len(topics))
	}
	var assertionId [32]byte
	copy(assertionId[:], topics[1])

	// data = (uint8 claimedSide, uint256 requestTimestamp)
	decoded, err := disputeForensicsDataABI.Unpack(log.Data)
	if err != nil {
		return "Decode failed", fmt.Errorf("unpack DisputeForensicsRequested: %w", err)
	}

	claimedSide := int(decoded[0].(uint8))
	requestTimestamp := decoded[1].(*big.Int).Int64()

	logger.Info(fmt.Sprintf("[Forensics] Assertion: 0x%x, side=%d, ts=%d", assertionId, claimedSide, requestTimestamp))

	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return "Chain not found", err
	}
	evmClient := &evm.Client{ChainSelector: chainSel}

	return forensicsEvidence(config, runtime, evmClient, assertionId, claimedSide, requestTimestamp)
}

// ═══════════════════════════════════════════════════════════════════
//  TRIGGER 3: HTTP — simulation & test entry point
//
//  ✅ Callback: func(config *C, runtime cre.Runtime, payload *http.Payload) (O, error)
//     Verified from credemos.com demo onHTTPTrigger
//  ✅ payload.Input = []byte (raw JSON from --http-payload)
// ═══════════════════════════════════════════════════════════════════

func onTestTrigger(config *Config, runtime cre.Runtime, payload *http.Payload) (string, error) {
	logger := runtime.Logger()
	config.applyDefaults()

	if len(payload.Input) == 0 {
		return "Empty payload", fmt.Errorf("HTTP payload is empty")
	}

	logger.Info(fmt.Sprintf("[CRE-Test] Payload: %s", string(payload.Input)))

	var data HTTPTestPayload
	if err := json.Unmarshal(payload.Input, &data); err != nil {
		return "Invalid JSON", fmt.Errorf("unmarshal failed: %w", err)
	}

	// Parse assertionId hex → [32]byte
	idHex := strings.TrimPrefix(data.AssertionID, "0x")
	idBytes, err := hex.DecodeString(idHex)
	if err != nil {
		return "Invalid assertionId", err
	}
	var assertionId [32]byte
	copy(assertionId[:], idBytes)

	if data.RequestTimestamp == 0 {
		data.RequestTimestamp = runtime.Now().Unix()
	}
	if data.Mode == "" {
		data.Mode = "watchdog"
	}

	logger.Info(fmt.Sprintf("[CRE-Test] mode=%s, side=%d, assertion=0x%x", data.Mode, data.ClaimedSide, assertionId))

	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return "Chain not found", err
	}
	evmClient := &evm.Client{ChainSelector: chainSel}

	if data.Mode == "forensics" {
		return forensicsEvidence(config, runtime, evmClient, assertionId, data.ClaimedSide, data.RequestTimestamp)
	}
	return watchdogDecision(config, runtime, evmClient, assertionId, data.ClaimedSide, data.RequestTimestamp)
}

// ═══════════════════════════════════════════════════════════════════
//  Workflow initialization — dual triggers + HTTP test entry
//
//  ✅ InitWorkflow signature verified from credemos.com demo + pkg.go.dev Runner
//  ✅ cre.Workflow[*Config]{...} verified
//  ✅ cre.Handler(trigger, callback) verified from pkg.go.dev
//  ✅ evm.LogTrigger(chainSel, config) verified from docs
//  ✅ http.Trigger(&http.Config{}) verified from credemos.com demo
// ═══════════════════════════════════════════════════════════════════

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	config.applyDefaults()

	// 📖 evm.ChainSelectorFromName — from docs
	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return nil, fmt.Errorf("unknown chain %s: %w", config.ChainSelectorName, err)
	}

	umaAddr := common.HexToAddress(config.UMAContractAddress)

	// TRIGGER 1: ResolutionRequested — no indexed params
	// ✅ evm.LogTrigger verified from docs evm-log-trigger-go reference page
	assertionTrigger := evm.LogTrigger(chainSel, &evm.FilterLogTriggerRequest{
		Addresses: [][]byte{umaAddr.Bytes()},
		Topics: []*evm.TopicValues{
			{Values: [][]byte{resolutionRequestedSig}},
		},
		Confidence: evm.ConfidenceLevel_CONFIDENCE_LEVEL_FINALIZED,
	})

	// TRIGGER 2: DisputeForensicsRequested — assertionId indexed
	// Only specify topics[0] (event sig). Omitting topics[1] matches any assertionId.
	disputeTrigger := evm.LogTrigger(chainSel, &evm.FilterLogTriggerRequest{
		Addresses: [][]byte{umaAddr.Bytes()},
		Topics: []*evm.TopicValues{
			{Values: [][]byte{disputeForensicsRequestedSig}},
		},
		Confidence: evm.ConfidenceLevel_CONFIDENCE_LEVEL_FINALIZED,
	})

	// TRIGGER 3: HTTP — simulation & test entry point
	// ✅ http.Trigger(&http.Config{}) verified from credemos.com demo
	httpTrigger := http.Trigger(&http.Config{})

	return cre.Workflow[*Config]{
		cre.Handler(assertionTrigger, onResolutionRequested),
		cre.Handler(disputeTrigger, onDisputeForensics),
		cre.Handler(httpTrigger, onTestTrigger),
	}, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Entry point
//
//  ✅ wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
//     Verified from credemos.com demo + pkg.go.dev Runner interface
// ═══════════════════════════════════════════════════════════════════

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
}
