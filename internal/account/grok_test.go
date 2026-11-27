package account

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

var grokProviderFixture = Provider{ID: "grok", DisplayName: "Grok Build"}

func TestGrokBillingPathsAndCycle(t *testing.T) {
	for _, tc := range []struct {
		name, json, label string
		pct               float64
		reset             string
	}{
		{"weekly", `{"creditUsagePercent":12.5,"billingCycle":{"billingPeriodStart":"2026-08-01T00:00:00Z","billingPeriodEnd":"2026-08-08T00:00:00Z"}}`, "7d", 12.5, "2026-08-08T00:00:00Z"},
		{"monthly", `{"usedPercent":40,"currentPeriod":{"start":"2026-07-01T00:00:00Z","end":"2026-07-31T00:00:00Z"}}`, "30d", 40, "2026-07-31T00:00:00Z"},
		{"wrapped", `{"config":{"creditUsagePercent":{"val":"8"}}}`, "7d", 8, ""},
		{"nested_period", `{"config":{"creditUsagePercent":51,"currentPeriod":{"start":"2026-08-26T11:25:34Z","end":"2026-09-02T11:25:34.373Z"}}}`, "7d", 51, "2026-09-02T11:25:34Z"},
		{"usage_limit", `{"usage":{"totalUsed":{"value":2500}},"monthlyLimit":{"val":"10000"}}`, "7d", 25, ""},
		{"clamp", `{"config":{"usagePercent":129}}`, "7d", 100, ""},
		{"explicit_zero", `{"usagePercent":0}`, "7d", 0, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, err := grokBillingJSON([]byte(tc.json), grokProviderFixture)
			if err != nil || len(s.Groups) != 1 || len(s.Groups[0].Items) != 1 {
				t.Fatalf("bad billing snapshot %v %v", s, err)
			}
			m := s.Groups[0].Items[0]
			if m.Label != tc.label || *m.UsedPercent != tc.pct || *m.RemainingPercent != 100-tc.pct || m.ResetAt != tc.reset || (m.ResetText != "") != (m.ResetAt != "") {
				t.Fatalf("wrong metric %+v", m)
			}
			if (tc.label == "30d") != (*m.WindowDurationMinutes == 43200) {
				t.Fatal(m.WindowDurationMinutes)
			}
		})
	}
	for _, raw := range []string{"{}", "[123]", `{"usedPercent":false}`, `{"usedPercent":"NaN"}`} {
		if _, err := grokBillingJSON([]byte(raw), grokProviderFixture); !errors.Is(err, errGrokNoQuota) {
			t.Errorf("invalid read %s accepted", raw)
		}
	}
}

func grokTestFrame(flag byte, b []byte) []byte {
	data := binary.BigEndian.AppendUint32([]byte{flag}, uint32(len(b)))
	return append(data, b...)
}
func grokTestPayload(percentage float32) []byte {
	body := binary.LittleEndian.AppendUint32([]byte{13}, math.Float32bits(percentage))
	ts := binary.AppendUvarint([]byte{8}, 1756809934)
	body = append(body, 42, byte(len(ts)))
	body = append(body, ts...)
	return append([]byte{10, byte(len(body))}, body...)
}

func TestGrokGRPCFrameAndStatus(t *testing.T) {
	for _, v := range []struct {
		in   float32
		want float64
	}{{0.51, 51}, {25, 25}, {0, 0}} {
		raw := grokTestPayload(v.in)
		for _, data := range [][]byte{raw, append(grokTestFrame(0, raw), grokTestFrame(0x80, []byte("grpc-status: 0\r\n"))...)} {
			s, err := grokBillingGRPC(data, grokProviderFixture)
			if err != nil {
				t.Fatal(err)
			}
			m := s.Groups[0].Items[0]
			if *m.UsedPercent != v.want || m.ResetAt != time.Unix(1756809934, 0).UTC().Format(time.RFC3339) {
				t.Fatal(m)
			}
		}
	}
	raw := append(grokTestFrame(0, grokTestPayload(.5)), grokTestFrame(0x80, []byte("grpc-status: 16\r\n"))...)
	if _, err := grokBillingGRPC(raw, grokProviderFixture); !errors.Is(err, errGrokLogin) {
		t.Fatal(err)
	}
	for _, data := range [][]byte{nil, {0, 0, 12}, {10, 2, 8, 0}, {0, 0, 0, 0, 1, 0}, {10, 16, 0x80}, {10, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2}} {
		if _, err := grokBillingGRPC(data, grokProviderFixture); err == nil {
			t.Fatalf("invalid payload %x accepted", data)
		}
	}
}

type grokTransport func(*http.Request) (*http.Response, error)

func (f grokTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func grokResponse(status int, data []byte) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(data))}
}
func grokTestAuth(t *testing.T, raw string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "auth.json")
	if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestGrokCLIRenewalWithoutSendingRefreshToken(t *testing.T) {
	auth := grokTestAuth(t, `{"https://auth.x.ai::test":{"key":"expired-fake","refresh_token":"local-only","expires_at":"2020-01-01T00:00:00Z"}}`)
	c := grokClient{billing: func(context.Context) ([]byte, error) { return []byte(`{"usedPercent":17}`), nil }}
	s, err := c.collect(t.Context(), grokProviderFixture, auth)
	if err != nil || *s.Groups[0].Items[0].UsedPercent != 17 {
		t.Fatal(s, err)
	}
	stale := grokTestAuth(t, `{"https://auth.x.ai::test":{"key":"expired-fake","expires_at":"2020-01-01T00:00:00Z"}}`)
	if _, err := c.collect(t.Context(), grokProviderFixture, stale); !errors.Is(err, errGrokLogin) {
		t.Fatal(err)
	}
	custom := grokTestAuth(t, `{"https://private.invalid::test":{"key":"private-local-only"}}`)
	c.billing = func(context.Context) ([]byte, error) { return nil, errGrokMethod }
	if _, err := c.collect(t.Context(), grokProviderFixture, custom); !errors.Is(err, errGrokMethod) {
		t.Fatal(err)
	}
}

func TestGrokReadFallbacks(t *testing.T) {
	for _, tc := range []struct {
		name       string
		restStatus int
		grpcStatus int
		rest       string
		resultErr  error
		want       []string
	}{
		{"rest", 200, 0, `{"usagePercent":51}`, nil, []string{"GET"}},
		{"grpc", 503, 200, "", nil, []string{"GET", "POST"}},
		{"no_fields_to_grpc", 200, 200, "{}", nil, []string{"GET", "POST"}},
		{"rest_expired", 401, 0, "", errGrokLogin, []string{"GET"}},
		{"grpc_denied", 500, 403, "", errGrokLogin, []string{"GET", "POST"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			auth := grokTestAuth(t, `{"https://auth.x.ai::test":{"key":"test-token","refresh_token":"renew-only","user_id":"u"}}`)
			var calls []string
			c := grokClient{billing: func(context.Context) ([]byte, error) { return nil, errGrokMethod }, client: &http.Client{Transport: grokTransport(func(r *http.Request) (*http.Response, error) {
				calls = append(calls, r.Method)
				if r.Header.Get("Authorization") != "Bearer test-token" || r.Header.Get("X-XAI-Token-Auth") != "xai-grok-cli" {
					return nil, errors.New("wrong headers")
				}
				if r.Method == "GET" {
					if r.URL.String() != grokBillingURL || r.Header.Get("x-userid") != "u" {
						return nil, errors.New("wrong REST request")
					}
					return grokResponse(tc.restStatus, []byte(tc.rest)), nil
				}
				body, _ := io.ReadAll(r.Body)
				if r.URL.String() != grokCreditsURL || r.Header.Get("Content-Type") != "application/grpc-web+proto" || r.Header.Get("x-userid") != "" || !bytes.Equal(body, []byte{0, 0, 0, 0, 0}) {
					return nil, errors.New("wrong gRPC request")
				}
				return grokResponse(tc.grpcStatus, grokTestFrame(0, grokTestPayload(.51))), nil
			})}}
			s, err := c.collect(t.Context(), grokProviderFixture, auth)
			if !errors.Is(err, tc.resultErr) || !slices.Equal(calls, tc.want) {
				t.Fatal(err, calls)
			}
			if err == nil && *s.Groups[0].Items[0].UsedPercent != 51 {
				t.Fatal(s)
			}
		})
	}
}

func billingFixtureProcess(ctx context.Context, mode string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestAgentBillingChildProcess$", "--", mode)
	cmd.Env = append(cmd.Environ(), "TOKENMETER_TEST_BILLING_CHILD=1")
	return cmd
}

func TestAgentBillingChildProcess(t *testing.T) {
	if os.Getenv("TOKENMETER_TEST_BILLING_CHILD") != "1" {
		return
	}
	mode := os.Args[len(os.Args)-1]
	if mode == "silent" {
		time.Sleep(time.Minute)
		return
	}
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		var msg map[string]any
		if json.Unmarshal(in.Bytes(), &msg) != nil {
			os.Exit(2)
		}
		if strings.HasPrefix(mode, "qoder") {
			rid := msg["request_id"]
			if rid == "tokenmeter-initialize" {
				if mode == "qoder-noquota" {
					fmt.Println(`{"type":"control_response","response":{"request_id":"tokenmeter-initialize","subtype":"success","response":{}}}`)
					continue
				}
				fmt.Println("ignored hook output")
				fmt.Println(`{"type":"control_response","response":{"request_id":"tokenmeter-initialize","subtype":"success","response":{"models":[{"value":"qmodel","modelId":"id1","displayName":"Example model","isEnabled":true},{"value":""}]}}}`)
			} else if rid == "tokenmeter-usage" {
				switch mode {
				case "qoder-noquota":
					fmt.Println(`{"type":"control_response","response":{"request_id":"tokenmeter-usage","subtype":"success","response":{"usage":{}}}}`)
				case "qoder-error":
					fmt.Println(`{"type":"control_response","response":{"request_id":"tokenmeter-usage","subtype":"error","error":"secret-must-not-be-printed"}}`)
				default:
					fmt.Println(`{"type":"control_response","response":{"request_id":"tokenmeter-usage","subtype":"success","response":{"usage":{"userQuota":{"used":12,"total":100}}}}}`)
				}
			}
			continue
		}
		id := int(msg["id"].(float64))
		method := msg["method"].(string)
		if id == 1 && method == "initialize" || id == 2 && method == "authenticate" {
			fmt.Printf("{\"id\":%d,\"result\":{}}\n", id)
			continue
		}
		if mode == "weekly" {
			fmt.Printf("{\"id\":%d,\"error\":{\"message\":\"weekly limit\"}}\n", id)
			continue
		}
		if method == "_x.ai/billing" && mode == "old" {
			fmt.Printf("{\"id\":%d,\"error\":{\"code\":-32601}}\n", id)
			continue
		}
		if (method == "_x.ai/billing" && mode == "new") || (method == "x.ai/billing" && mode == "old") {
			fmt.Println(`{"method":"unrelated-notification"}`)
			fmt.Printf("{\"id\":%d,\"result\":{\"creditUsagePercent\":12}}\n", id)
			continue
		}
		os.Exit(3)
	}
	os.Exit(0)
}
func TestGrokRPC(t *testing.T) {
	for _, mode := range []string{"new", "old", "weekly", "silent"} {
		t.Run(mode, func(t *testing.T) {
			limit := 3 * time.Second
			if mode == "silent" {
				limit = 150 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(t.Context(), limit)
			defer cancel()
			b, err := grokBillingRPC(ctx, billingFixtureProcess(ctx, mode))
			switch mode {
			case "silent":
				if !errors.Is(err, context.DeadlineExceeded) {
					t.Fatal(err)
				}
			case "weekly":
				if !errors.Is(err, errGrokLimit) {
					t.Fatal(err)
				}
			default:
				if err != nil || !strings.Contains(string(b), "creditUsagePercent") {
					t.Fatal(string(b), err)
				}
			}
		})
	}
}

func TestGrokSeparatesReportedMoneyFromPercentages(t *testing.T) {
	const raw = `{"config":{"creditUsagePercent":55,"monthlyLimit":{"val":"9007199254740993"},"used":{"val":1250},"onDemandCap":{"val":15000},"onDemandUsed":{"val":250},"prepaidBalance":{"val":1446}}}`
	s, err := grokBillingJSON([]byte(raw), grokProviderFixture)
	if err != nil || len(s.Groups) != 2 || len(s.Groups[1].Items) != 3 {
		t.Fatal(s, err)
	}
	window := s.Groups[0].Items[0]
	if *window.RemainingPercent != 45 || window.RemainingAmount != "" || window.UsedAmount != "" || window.Unit != "" {
		t.Fatal(window)
	}
	included, extra, wallet := s.Groups[1].Items[0], s.Groups[1].Items[1], s.Groups[1].Items[2]
	if included.Unit != "USD" || included.UsedAmount != "12.50" || included.TotalAmount != "90071992547409.93" || included.RemainingAmount != "" {
		t.Fatal(included)
	}
	if extra.UsedAmount != "2.50" || extra.TotalAmount != "150.00" || extra.RemainingAmount != "" || extra.Unit != "USD" {
		t.Fatal(extra)
	}
	if wallet.Kind != "balance" || wallet.RemainingAmount != "14.46" || wallet.UsedAmount != "" || wallet.TotalAmount != "" || wallet.Unit != "USD" {
		t.Fatal(wallet)
	}
}

func TestGrokMoneyWithNoReportedPercent(t *testing.T) {
	for _, tc := range []struct {
		payload                                      string
		expectedRemaining, expectedUsed, expectedCap string
		pct                                          *float64
	}{
		{`{"config":{"prepaidBalance":{}}}`, "0.00", "", "", nil},
		{`{"config":{"prepaidBalance":{"val":500}}}`, "5.00", "", "", nil},
		{`{"monthlyLimit":0,"totalUsed":1}`, "", "0.01", "0.00", nil},
		{`{"monthlyLimit":{"val":10000},"usage":{"totalUsed":{"val":2500},"onDemandUsed":{"val":500}}}`, "", "20.00", "100.00", new(float64(20))},
	} {
		s, err := grokBillingJSON([]byte(tc.payload), grokProviderFixture)
		if err != nil {
			t.Fatal(err)
		}
		m := s.Groups[0].Items[0]
		if m.RemainingAmount != tc.expectedRemaining || m.UsedAmount != tc.expectedUsed || m.TotalAmount != tc.expectedCap || m.Unit != "USD" || (m.UsedPercent == nil) != (tc.pct == nil) || tc.pct != nil && *m.UsedPercent != *tc.pct {
			t.Fatal(tc.payload, m)
		}
	}
	for _, raw := range []string{`{"prepaidBalance":null}`, `{"prepaidBalance":{"val":"NaN"}}`, `{"prepaidBalance":{"val":-1}}`, `{"prepaidBalance":{"other":1}}`, `{"prepaidBalance":{"val":1.5}}`} {
		if _, err := grokBillingJSON([]byte(raw), grokProviderFixture); !errors.Is(err, errGrokNoQuota) {
			t.Fatal(raw, err)
		}
	}
}
