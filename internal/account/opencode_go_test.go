package account

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestOpenCodeGoOfficialAPI(t *testing.T) {
	p := Provider{ID: "opencode-go", DisplayName: "OpenCode Go"}
	c := &http.Client{Transport: billingTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != openCodeGoAPI || r.Header.Get("Authorization") != "Bearer key" || r.Header.Get("Cookie") != "" {
			t.Error("unexpected API authentication or origin")
		}
		return billingTestResponse(200, `{"usage":{"rolling":{"status":"ok","percent":1,"resetsAt":"2026-11-21T15:00:00.456Z"},"weekly":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-23T00:00:00.000Z"},"monthly":{"status":"ok","percent":50,"resetsAt":"2026-12-01T00:00:00.000Z"}}}`), nil
	})}
	s, err := fetchOpenCodeAPI(context.Background(), c, p, "key")
	if err != nil {
		t.Fatal(err)
	}
	if s.Summary != "5h 99% · Weekly 0% · Monthly 50%" {
		t.Errorf("bad summary %v", s)
	}
	m := s.Groups[0].Items
	if m[0].ResetAt != "2026-11-21T15:00:00Z" || *m[1].WindowDurationMinutes != 10080 || *m[2].WindowDurationMinutes != 43200 {
		t.Errorf("bad windows %+v", m)
	}
	for _, window := range m {
		if window.UsedAmount != "" || window.RemainingAmount != "" || window.TotalAmount != "" || window.Unit != "" {
			t.Fatalf("percentage-only response acquired an absolute amount: %+v", window)
		}
	}
}

func TestOpenCodeGoConsoleSupportsScopedSession(t *testing.T) {
	p := Provider{ID: "opencode-go", DisplayName: "OpenCode Go"}
	for _, cred := range []openCodeSession{
		{WorkspaceID: "org_test", AuthCookie: "legacy"},
		{WorkspaceID: "org_test", ConsoleSession: "current"},
		{WorkspaceID: "org_test", AuthCookie: "legacy", ConsoleSession: "current"},
	} {
		c := &http.Client{Transport: billingTestTransport(func(r *http.Request) (*http.Response, error) {
			if r.URL.String() != openCodeGoConsole || r.Header.Get("X-Org-Id") != cred.WorkspaceID || r.Header.Get("Authorization") != "" {
				t.Error("unexpected scope/origin")
			}
			for name, want := range map[string]string{"auth": cred.AuthCookie, "__Host-console_session": cred.ConsoleSession} {
				v, err := r.Cookie(name)
				if (want == "") != (err != nil) || (err == nil && v.Value != want) {
					t.Error("wrong cookie selection")
				}
			}
			return billingTestResponse(200, `{"access":{"endsAt":"2026-12-28T00:00:00Z","meters":{"fiveHour":{"usedMicroCents":"20","limitMicroCents":"100","resetsAt":"2026-12-01T02:00:00Z"},"month":{"usedMicroCents":0,"limitMicroCents":9007199254740993}}}}`), nil
		})}
		s, err := fetchOpenCodeSession(context.Background(), c, p, cred)
		if err != nil {
			t.Fatal(err)
		}
		m := s.Groups[0].Items
		if len(m) != 2 || s.Message != "5h 80% · Monthly 100%" || m[1].ResetAt != "" {
			t.Errorf("missing-window or resets regression %+v", s)
		}
		if m[0].UsedAmount != "0.0000002" || m[0].TotalAmount != "0.000001" || m[0].RemainingAmount != "" || m[0].Unit != "USD" || m[1].UsedAmount != "0" || m[1].TotalAmount != "90071992.54740993" {
			t.Fatalf("incorrect allowance in dollars: %+v", m)
		}
	}
}

func TestOpenCodeGoWorkspaceAndKeyDiscovery(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, ".config", "opencode", "opencode-quota")
	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "opencode-go.json"), []byte(`{"workspaceId":"existing","authCookie":"saved"}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OPENCODE_GO_WORKSPACE_ID", "incomplete")
	t.Setenv("OPENCODE_GO_AUTH_COOKIE", "")
	t.Setenv("OPENCODE_GO_CONSOLE_SESSION", "")
	s, ok := openCodeSessionFor(home)
	if !ok || s.WorkspaceID != "existing" || s.AuthCookie != "saved" {
		t.Fatal("lost persisted credentials")
	}
	t.Setenv("OPENCODE_GO_CONSOLE_SESSION", "new")
	if s, ok = openCodeSessionFor(home); !ok || s.ConsoleSession != "new" || s.WorkspaceID != "incomplete" {
		t.Fatal("did not prefer explicit context")
	}
	data := filepath.Join(home, "data")
	t.Setenv("XDG_DATA_HOME", data)
	t.Setenv("OPENCODE_GO_API_KEY", "")
	t.Setenv("OPENCODE_API_KEY", "")
	if err := os.MkdirAll(filepath.Join(data, "opencode"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "opencode", "auth.json"), []byte(`{"opencode":{"type":"api","key":"zen"},"opencode-go":{"type":"api","key":"go"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if k := openCodeAPIKey(home); k != "go" {
		t.Fatal("wrong billing key source")
	}
}

func TestOpenCodeGoDiagnosesMissingWindowsAndUnauthenticated(t *testing.T) {
	p := Provider{ID: "opencode-go", DisplayName: "OpenCode Go"}
	for _, row := range []map[string]openCodeMeter{nil, {"fiveHour": {LimitMicroCents: "0", UsedMicroCents: "3"}}, {"month": {LimitMicroCents: "12"}}} {
		if _, err := openCodeSnapshot(p, row, true, time.Now()); err == nil {
			t.Fatal("fabricated percentage")
		}
	}
	c := &http.Client{Transport: billingTestTransport(func(*http.Request) (*http.Response, error) { return billingTestResponse(401, "fixture secret"), nil })}
	if _, err := fetchOpenCodeAPI(context.Background(), c, p, "fixture"); err == nil || !strings.Contains(err.Error(), "重新连接") || strings.Contains(err.Error(), "fixture") {
		t.Fatalf("bad login error %v", err)
	}
}

func TestOpenCodeGoReadsV2CLIWithIsolatedHome(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX fixture executable")
	}
	home := t.TempDir()
	dir := filepath.Join(home, "bin")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	const script = `#!/bin/sh
test "$1" = api && test "$2" = get && test "$3" = /api/experimental/usage/limits && test "$#" = 3 || exit 2
test "$HOME" = "$PWD" && test "$XDG_DATA_HOME" = "$HOME/.local/share" || exit 3
printf '%s' '{"go":{"rolling":{"percent":10,"limited":false,"resetsAt":1735689600000},"weekly":{"percent":100,"limited":true}}}'
`
	if err := os.WriteFile(filepath.Join(dir, "opencode"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"OPENCODE_GO_WORKSPACE_ID", "OPENCODE_GO_AUTH_COOKIE", "OPENCODE_GO_CONSOLE_SESSION", "OPENCODE_GO_API_KEY", "OPENCODE_API_KEY", "XDG_DATA_HOME"} {
		t.Setenv(k, "")
	}
	t.Setenv("PATH", dir)
	s, err := collectOpenCodeGo(t.Context(), Environment{Home: home}, Provider{ID: "opencode-go", DisplayName: "OpenCode Go"})
	if err != nil {
		t.Fatal(err)
	}
	if s.Summary != "5h 90% · Weekly 0%" || s.Groups[0].Items[0].ResetAt != "2025-01-01T00:00:00Z" || s.Groups[0].Items[1].Detail == "" {
		t.Fatalf("bad CLI quota %+v", s)
	}
	if m := s.Groups[0].Items[0]; m.UsedAmount != "" || m.RemainingAmount != "" || m.TotalAmount != "" || m.Unit != "" {
		t.Fatalf("CLI reported no amounts: %+v", m)
	}
}
