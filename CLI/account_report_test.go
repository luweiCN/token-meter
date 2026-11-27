package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestManualAccountRefreshPreservesLocalUsageAndWalletUnits(t *testing.T) {
	s := testStore(t)
	base := filepath.Join(s.home, ".token-meter")
	config := []byte(`{"providers":[{"id":"manual","displayName":"Balance","enabled":true,"type":"manual","manualUsage":{"status":"ok","label":"balance","remaining":9007199254740993.12345,"unit":"CNY"}}]}`)
	writeTestFile(t, filepath.Join(base, "config.json"), config)
	t.Setenv("TOKENMETER_CONFIG", filepath.Join(base, "config.json"))
	check(t, s.publish([]Bucket{{Day: "2026-01-01", Agent: "openclaw", Model: "m", Counts: Counts{Input: 9, Events: 1}}}, nil, 1))
	check(t, s.refreshAccounts(context.Background(), "manual", true))
	r, err := s.report("local", "", "")
	check(t, err)
	if r.Tokens != 9 || len(r.Devices) != 1 || r.Devices[0].PartialSources != 1 || len(r.Quotas) != 1 || len(r.Quotas[0].Windows) != 1 {
		t.Fatal("refresh replaced usage or dropped the amount")
	}
	w := r.Quotas[0].Windows[0]
	if w.Remaining != nil || w.RemainingAmount != "9007199254740993.12345" || w.Unit != "CNY" {
		t.Fatalf("wrong quantity %+v", w)
	}
	data, err := os.ReadFile(filepath.Join(base, "cache", "provider-snapshots.json"))
	check(t, err)
	if !json.Valid(data) {
		t.Fatal("invalid local display snapshot")
	}
	for _, tc := range []struct{ input, amount, unit string }{
		{`{"codex":{"_0":{"amount":{"_0":"51007.11399125"}}}}`, "51007.11399125", ""},
		{`{"codex":{"_0":{"noCredits":{}}}}`, "0", ""},
		{`{"codex":{"_0":{"unavailable":{}}}}`, "", ""},
		{`{"claude":{"prepaid":{"value":0.12,"currency":"USD"}}}`, "0.12", "USD"},
		{`{"claude":{"prepaid":{"value":"NaN","currency":"USD"}}}`, "", "USD"},
	} {
		v, unit := readWallet([]byte(tc.input))
		if v != tc.amount || unit != tc.unit {
			t.Fatalf("wallet expected %q %q, got %q %q", tc.amount, tc.unit, v, unit)
		}
	}
}
