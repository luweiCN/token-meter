package account

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestAntigravityQuotaBucketsAndGrouping(t *testing.T) {
	now := time.Date(2028, 3, 11, 3, 0, 0, 200_000_000, time.UTC)
	payload := `{"email":"not-for-cache@example.invalid","conversation_title":"private",
		"quota":{"gemini-5h":{"remaining_fraction":0,"reset_time":"2028-03-11T04:00:00.731Z"},
			"gemini-weekly":{"remaining_fraction":0.75},"3p-5h":{"remaining_fraction":0.9,"reset_time":"1970-01-01T00:00:00Z"},
			"3p-weekly":{"remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":120},
			"gemini-argon-wtu-weekly":{"remaining_fraction":0.45},"new-limit":{"remaining_amount":15},
			"invalid":{"remaining_fraction":2},"broken":"not an object","disabled":{"remaining_amount":3,"disabled":true}}}`
	obs, err := agyParse([]byte(payload), now)
	if err != nil || len(obs.Buckets) != 6 {
		t.Fatalf("buckets: %v %v", obs, err)
	}
	data, _ := json.Marshal(obs)
	if strings.Contains(string(data), "private") || strings.Contains(string(data), "@") {
		t.Fatal("unrelated status line data present")
	}
	p := Provider{ID: "antigravity", DisplayName: "Antigravity"}
	result := agySnapshot(p, obs, now, nil)
	if result.DisplayName != "AGY" || result.Status != "ok" || len(result.Groups) != 4 {
		t.Fatal(result)
	}
	if result.Groups[0].Title != "Gemini" || result.Groups[1].Title != "Claude/GPT" || result.Groups[2].Title != "Gemini Argon WTU" {
		t.Fatal(result.Groups)
	}
	small := result.Groups[0].Items[0]
	if small.ID != "gemini-5h" || *small.RemainingPercent != 0 || *small.WindowDurationMinutes != 300 || small.Status != "warning" || small.ResetAt != "2028-03-11T04:00:00Z" {
		t.Fatal(small)
	}
	if result.Groups[1].Items[0].ResetAt != "" || result.Groups[1].Items[1].ResetAt != "2028-03-11T03:02:00Z" {
		t.Fatal(result.Groups[1])
	}
	if a := result.Groups[3].Items[0]; a.Detail != "剩余 15" || a.RemainingPercent != nil || a.WindowDurationMinutes != nil {
		t.Fatal(a)
	}
	late := agySnapshot(p, obs, now.Add(time.Hour), agyQueryError("not currently available in your location", false))
	if late.Status != "warning" || len(late.Groups[0].Items) != 1 || late.Groups[0].Items[0].ID != "gemini-weekly" || late.FetchedAt != result.FetchedAt {
		t.Fatal(late)
	}
}

func TestAntigravityExactAmountAndOptionalUnit(t *testing.T) {
	now := time.Now()
	payload := []byte(`{"quota":{
		"amount-only":{"remaining_amount":9007199254740993.00000001234,"unit":"WTU"},
		"both":{"remaining_fraction":0.5,"remaining_amount":0.0500,"unit":"credits"},
		"unknown-unit":{"remaining_amount":0},
		"negative":{"remaining_amount":-2},
		"private-label":{"remaining_amount":2,"unit":"private@example.invalid"}
	}}`)
	obs, err := agyParse(payload, now)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(obs)
	if err != nil || bytes.Contains(data, []byte("@")) {
		t.Fatal(err, string(data))
	}
	var cached agyObservation
	if err := json.Unmarshal(data, &cached); err != nil {
		t.Fatal(err)
	}
	s := agySnapshot(Provider{ID: "antigravity"}, &cached, now, nil)
	metrics := map[string]Metric{}
	for _, g := range s.Groups {
		for _, m := range g.Items {
			metrics[m.ID] = m
		}
	}
	a := metrics["amount-only"]
	if a.RemainingAmount != "9007199254740993.00000001234" || a.Unit != "WTU" || a.Detail != "剩余 9007199254740993.00000001234 WTU" || a.RemainingPercent != nil || a.UsedAmount != "" || a.TotalAmount != "" {
		t.Fatal(a)
	}
	b := metrics["both"]
	if b.RemainingAmount != "0.0500" || b.RemainingPercent == nil || *b.RemainingPercent != 50 || b.UsedAmount != "" || b.TotalAmount != "" {
		t.Fatal(b)
	}
	if unknown := metrics["unknown-unit"]; unknown.RemainingAmount != "0" || unknown.Unit != "" {
		t.Fatal(unknown)
	}
	if metrics["private-label"].Unit != "" || len(metrics) != 4 {
		t.Fatal(metrics)
	}
}

func TestAntigravityObservationFreshnessAndSignout(t *testing.T) {
	home := t.TempDir()
	cli := filepath.Join(home, "token-meter")
	if err := AntigravityHook(home, cli, true); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Add(-time.Minute)
	payload := []byte(`{"quota":{"gemini-5h":{"remaining_fraction":0.75,"reset_time":"2028-03-11T04:00:00.731Z"}}}`)
	obs, _ := agyParse(payload, now)
	if err := agySave(home, obs, now, true); err != nil {
		t.Fatal(err)
	}
	next, _ := agyParse(payload, now.Add(time.Second))
	if err := agySave(home, next, next.ObservedAt, true); err != nil {
		t.Fatal(err)
	}
	if actual := agyRead(home); !actual.ObservedAt.Equal(now) {
		t.Fatal("identical reading not coalesced")
	}
	live, _ := agyParse([]byte(`{"quota":{"3p-5h":{"remaining_fraction":0.2}}}`), now.Add(5*time.Second))
	if err := agySave(home, live, live.ObservedAt, true); err != nil {
		t.Fatal(err)
	}
	if err := agySave(home, next, now, false); err != nil {
		t.Fatal(err)
	}
	if _, ok := agyRead(home).Buckets["3p-5h"]; !ok {
		t.Fatal("stale worker overwrote session reading")
	}
	for _, partial := range []string{`{"context_window":{"remaining_percentage":0}}`, `{"agent_state":"initializing","quota":{}}`} {
		obs, err := agyParse([]byte(partial), now)
		if err != nil || obs != nil {
			t.Fatal(partial, obs, err)
		}
	}
	if err := AntigravityCapture(home, nil, strings.NewReader(`{"agent_state":"authenticating"}`), io.Discard); err != nil {
		t.Fatal(err)
	}
	result, err := collectAntigravity(context.Background(), Environment{Home: home}, Provider{ID: "antigravity"})
	if err != nil || len(result.Groups) != 0 || result.Status != "warning" || !strings.Contains(result.Message, "等待") {
		t.Fatal(result, err)
	}
	if err = AntigravityHook(home, cli, false); err != nil {
		t.Fatal(err)
	}
	if err = agySave(home, live, now, false); err != nil || agyRead(home) != nil {
		t.Fatal("disabled observation", err)
	}
}

func TestAntigravityHookMigratesOriginalAndPreservesUserEdits(t *testing.T) {
	home := t.TempDir()
	cli := filepath.Join(home, "TokenMeter 'space", "token-meter")
	if runtime.GOOS == "windows" {
		cli = filepath.Join(home, "TokenMeter space", "token-meter.exe")
	}
	settings, err := agySettingsPath(home)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(settings), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(agyCache(home), 0700); err != nil {
		t.Fatal(err)
	}
	custom := "tr a-z A-Z"
	if runtime.GOOS == "windows" {
		custom = "findstr /R .*"
	}
	original, _ := json.Marshal(map[string]any{"type": "command", "command": custom, "padding": 2, "stack_with_default": false})
	if err := agyWritePrivate(agyConnectionPath(home), agyConnection{Original: original}); err != nil {
		t.Fatal(err)
	}
	line := agySettings{}
	_ = json.Unmarshal(original, &line)
	line.put("command", "old --capture-antigravity-quota --passthrough | (...)"+agyPreviousMarker)
	line.put("enabled", true)
	doc := agySettings{}
	doc.put("statusLine", line)
	doc.put("unrelated", 17)
	if err := agyWritePrivate(settings, doc); err != nil {
		t.Fatal(err)
	}
	if err := AntigravityHook(home, cli, true); err != nil {
		t.Fatal(err)
	}
	var updated struct {
		StatusLine agySettings
		Unrelated  int
	}
	if err := agyReadJSON(settings, &updated, 1<<20); err != nil {
		t.Fatal(err)
	}
	cmd := updated.StatusLine.text("command")
	if !strings.Contains(cmd, "antigravity-capture --forward") || strings.Contains(cmd, "--capture-antigravity-quota") || updated.Unrelated != 17 {
		t.Fatal(updated)
	}
	before, _ := os.ReadFile(settings)
	if err := AntigravityHook(home, cli, true); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(settings)
	if !bytes.Equal(before, after) {
		t.Fatal("second install changed settings")
	}
	if runtime.GOOS != "windows" {
		var out bytes.Buffer
		if err := AntigravityCapture(home, []string{"--forward", agyHookMarker}, strings.NewReader("custom status\n"), &out); err != nil || out.String() != "CUSTOM STATUS\n" {
			t.Fatal(err, out.String())
		}
		large := strings.Repeat("x", agyPayloadLimit+128)
		out.Reset()
		if err := AntigravityCapture(home, []string{"--forward"}, strings.NewReader(large), &out); err != nil || out.String() != strings.ToUpper(large) {
			t.Fatal("oversize forwarding", err)
		}
	}
	if err := AntigravityHook(home, cli, false); err != nil {
		t.Fatal(err)
	}
	if err := agyReadJSON(settings, &updated, 1<<20); err != nil {
		t.Fatal(err)
	}
	if updated.StatusLine.text("command") != custom || updated.StatusLine.text("type") != "command" || string(updated.StatusLine["padding"]) != "2" {
		t.Fatal(updated)
	}
	if err := AntigravityHook(home, cli, true); err != nil {
		t.Fatal(err)
	}
	replaced := []byte(`{"other":true,"statusLine":{"command":"echo mine","type":"command"}}`)
	if err := os.WriteFile(settings, replaced, 0600); err != nil {
		t.Fatal(err)
	}
	if err := AntigravityHook(home, cli, true); err != nil {
		t.Fatal(err)
	}
	if err := AntigravityHook(home, cli, false); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(settings); !bytes.Equal(got, replaced) {
		t.Fatal("overwrote separately replaced hook")
	}
}

func TestAntigravityDocumentedFailuresAndFreshLogin(t *testing.T) {
	checks := []struct {
		log     string
		timeout bool
		want    string
	}{
		{"OAuth error: invalid_grant account@example.invalid", false, "登录"},
		{"token refresh failed due to network error; Print mode: triggering interactive OAuth", true, "续期"},
		{"Account ineligible: not currently available in your location", true, "地区"},
		{"Account ineligible: not eligible", false, "资格"},
		{"Print mode: triggering interactive OAuth", true, "登录"},
		{"doRefreshQuota: skipped (not logged in)", true, "超时"},
		{"unexpected host@example.invalid", false, "稍后"},
	}
	for _, c := range checks {
		err := agyQueryError(c.log, c.timeout)
		if !strings.Contains(err.Error(), c.want) || strings.Contains(err.Error(), "@") {
			t.Fatal(c, err)
		}
	}
	home := t.TempDir()
	if err := AntigravityHook(home, filepath.Join(home, "token-meter"), true); err != nil {
		t.Fatal(err)
	}
	snap, err := collectAntigravity(context.Background(), Environment{Home: home, Force: true}, Provider{ID: "antigravity"})
	if err != nil || snap.Message != agySignIn.Error() || snap.Status != "error" {
		t.Fatal(snap, err)
	}
}

// AGY invokes its status line through the platform shell. Using the test binary
// at both ends exercises the same native PTY/ConPTY and argument boundaries as
// the shipped executable, without consulting an installed AGY or login.
func init() {
	mode := os.Getenv("TOKENMETER_TEST_AGY")
	if mode == "" || len(os.Args) < 2 {
		return
	}
	switch os.Args[1] {
	case "antigravity-capture":
		if err := AntigravityCapture(os.Getenv("HOME"), os.Args[2:], os.Stdin, io.Discard); err != nil {
			os.Exit(3)
		}
		os.Exit(0)
	case "--log-file":
		os.Exit(agyFixture(mode, os.Args[1:]))
	}
}

func agyFixture(mode string, args []string) int {
	if len(args) != 4 || args[2] != "--settings" || os.Getenv("SSH_CONNECTION") == "" || os.Getenv("ANTIGRAVITY_REMOTE_OOB_AUTH") != "true" || os.Getenv("DISPLAY") != "" {
		return 21
	}
	if stat, err := os.Stdin.Stat(); err != nil || (stat.Mode()&os.ModeCharDevice) == 0 {
		return 22
	}
	if runtime.GOOS != "windows" {
		tty, err := os.Open("/dev/tty")
		if err != nil {
			return 23
		}
		tty.Close()
	}
	if runtime.GOOS == "darwin" {
		if err := exec.Command("/usr/bin/open", "--help").Run(); err == nil {
			return 24
		}
	}
	if err := os.WriteFile(filepath.Join(os.Getenv("HOME"), "observed-log"), []byte(args[1]), 0600); err != nil {
		return 25
	}
	if mode == "region" {
		if err := os.WriteFile(args[1], []byte("Account ineligible: not currently available in your location (account@example.invalid)"), 0600); err != nil {
			return 26
		}
	} else {
		if mode == "terminal-probe" {
			raw := exec.Command("stty", "-icanon", "-echo", "min", "1", "time", "0")
			raw.Stdin = os.Stdin
			if err := raw.Run(); err != nil {
				return 29
			}
			for _, probe := range []string{"\x1b[>c", "\x1b[>0c"} {
				os.Stdout.WriteString(probe[:3])
				time.Sleep(20 * time.Millisecond)
				os.Stdout.WriteString(probe[3:])
				var reply [9]byte
				if _, err := io.ReadFull(os.Stdin, reply[:]); err != nil || string(reply[:]) != "\x1b[>0;0;0c" {
					return 30
				}
			}
		}
		var settings struct{ StatusLine struct{ Command string } }
		if err := json.Unmarshal([]byte(args[3]), &settings); err != nil || settings.StatusLine.Command == "" {
			return 27
		}
		for _, payload := range []string{`{"agent_state":"initializing","quota":{}}`, `{"email":"private@example.invalid","quota":{"gemini-5h":{"remaining_fraction":0},"3p-weekly":{"remaining_fraction":0.8}}}`} {
			cmd := agyShell(settings.StatusLine.Command)
			cmd.Stdin = strings.NewReader(payload)
			if err := cmd.Run(); err != nil {
				return 28
			}
		}
	}
	time.Sleep(30 * time.Second)
	return 0
}

func TestAntigravityUnattendedTerminalProbe(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX controlling-terminal fixture")
	}
	home := t.TempDir()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TOKENMETER_TEST_AGY", "terminal-probe")
	t.Setenv("GORACE", "atexit_sleep_ms=0")
	t.Setenv("TERM_PROGRAM", "")
	obs, err := agyBackground(context.Background(), Environment{Home: home}, exe, exe, 3*time.Second)
	if err != nil || obs == nil || len(obs.Buckets) != 2 {
		t.Fatalf("quota after terminal identification: %v", err)
	}
}

func TestAntigravityBackgroundPTY(t *testing.T) {
	home := t.TempDir()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TOKENMETER_TEST_AGY", "success")
	t.Setenv("GORACE", "atexit_sleep_ms=0")
	env := Environment{Home: home}
	obs, err := agyBackground(context.Background(), env, exe, exe, 6*time.Second)
	if err != nil || len(obs.Buckets) != 2 {
		t.Fatal(obs, err)
	}
	log, _ := os.ReadFile(filepath.Join(home, "observed-log"))
	if _, err := os.Stat(string(log)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("temporary diagnostic left behind")
	}
	t.Setenv("TOKENMETER_TEST_AGY", "region")
	_, err = agyBackground(context.Background(), env, exe, exe, 1000*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "地区") || strings.Contains(err.Error(), "@") {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	after := time.AfterFunc(200*time.Millisecond, cancel)
	defer after.Stop()
	defer cancel()
	_, err = agyBackground(ctx, env, exe, exe, 6*time.Second)
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
