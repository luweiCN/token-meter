package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/luweiCN/token-meter/internal/account"
)

func atomicJSON(path string, v any) error {
	f, e := os.CreateTemp(filepath.Dir(path), ".token-meter-*")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = json.NewEncoder(f).Encode(v); e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e != nil {
		return e
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(name, path)
}
func loadOptional(path string, v any) error {
	f, e := os.Open(path)
	if os.IsNotExist(e) {
		return nil
	}
	if e != nil {
		return e
	}
	defer f.Close()
	return json.NewDecoder(io.LimitReader(f, 8<<20)).Decode(v)
}
func (s *Store) account(provider string) string { return s.setting("account."+provider, s.id) }
func decimalBalance(raw json.RawMessage) string {
	var n json.Number
	if json.Unmarshal(raw, &n) == nil {
		return account.DecimalAmount(n.String())
	}
	return ""
}
func (q Quota) balanceLabel() string {
	if q.BalanceUnit != "" {
		return q.BalanceUnit
	}
	return "credits"
}

func readWallet(raw json.RawMessage) (balance, unit string) {
	var wallet struct {
		Codex struct {
			Value struct {
				Amount struct {
					Value json.RawMessage `json:"_0"`
				}
				Unlimited, NoCredits *struct{}
			} `json:"_0"`
		}
		Claude struct {
			Prepaid *struct {
				Value    json.RawMessage
				Currency string
			}
		}
	}
	if len(raw) == 0 || json.Unmarshal(raw, &wallet) != nil {
		return "", ""
	}
	if p := wallet.Claude.Prepaid; p != nil && p.Currency != "" {
		return decimalBalance(p.Value), p.Currency
	}
	value := wallet.Codex.Value
	switch {
	case value.Unlimited != nil:
		return "unlimited", ""
	case value.NoCredits != nil:
		return "0", ""
	default:
		return decimalBalance(value.Amount.Value), ""
	}
}

func (s *Store) readQuotas() ([]Quota, error) {
	providers, err := account.Read(s.home)
	if err != nil {
		return nil, err
	}
	out := []Quota{}
	for _, p := range providers {
		if p.ProviderID == "" || p.FetchedAt == "" {
			continue
		}
		q := Quota{Provider: p.ProviderID, Account: s.account(p.ProviderID), Observed: p.FetchedAt}
		for _, g := range p.Groups {
			for _, m := range g.Items {
				if m.Kind == "tokens" || (m.RemainingPercent == nil && m.RemainingAmount == "" && m.UsedAmount == "" && m.TotalAmount == "") {
					continue
				}
				label := m.Label
				if len(p.Groups) > 1 && g.Title != "" && g.Title != p.DisplayName {
					label = g.Title + " " + label
				}
				q.Windows = append(q.Windows, Window{ID: m.ID, Label: label, Remaining: m.RemainingPercent, ResetAt: m.ResetAt,
					UsedAmount: m.UsedAmount, RemainingAmount: m.RemainingAmount, TotalAmount: m.TotalAmount, Unit: m.Unit})
			}
		}
		q.Balance, q.BalanceUnit = readWallet(p.AccountCredits)
		if len(q.Windows) > 0 || q.Balance != "" {
			out = append(out, q)
		}
	}
	var extra []Quota
	if err = loadOptional(filepath.Join(s.dir, "openclaw-quota.json"), &extra); err != nil {
		return nil, err
	}
	for _, q := range extra {
		q.Account = s.account(q.Provider)
		out = append(out, q)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Provider < out[j].Provider })
	return out, nil
}

// Pull account balances independently of indexing historical session files.
func (s *Store) refreshAccounts(ctx context.Context, only string, force bool) error {
	if _, err := os.Stat(filepath.Join(s.dir, "index-paused")); err == nil {
		if force {
			return errors.New("采集已暂停")
		}
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	var upstream, accounts error
	if force && (only == "" || only == "openclaw") {
		upstream = s.refreshClawQuota(ctx)
	}
	if only != "openclaw" {
		if force {
			accounts = account.Refresh(ctx, s.home, only)
		} else {
			accounts = account.RefreshDue(ctx, s.home)
		}
	}
	if err := errors.Join(upstream, accounts); err != nil {
		return err
	}
	if !force {
		return nil
	} // the minute scan publishes automatic reads
	return s.writeSnapshot(func(snap *Snapshot) error {
		quotas, err := s.readQuotas()
		if err == nil {
			snap.Quotas = quotas
		}
		return err
	})
}

func (s *Store) checkResetCards(ctx context.Context) error {
	result, err := account.CheckCodexReset(ctx, s.home, func() bool {
		_, err := os.Stat(filepath.Join(s.dir, "index-paused"))
		return os.IsNotExist(err)
	})
	if ctx.Err() != nil {
		return ctx.Err()
	}
	path := filepath.Join(s.dir, "codex-reset-status.json")
	var old account.CodexResetResult
	if readErr := loadOptional(path, &old); readErr != nil || old.Status != result.Status || old.Message != result.Message {
		err = errors.Join(err, atomicJSON(path, result))
	}
	if result.Consumed {
		err = errors.Join(err, s.refreshAccounts(ctx, "codex", true))
	}
	return err
}

type limitedBuffer struct {
	bytes.Buffer
	max int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if len(p) > b.max-b.Len() {
		return 0, errors.New("quota response exceeds size limit")
	}
	return b.Buffer.Write(p)
}
func (s *Store) refreshClawQuota(ctx context.Context) error {
	if _, e := os.Stat(filepath.Join(s.setting("openclaw", rootDir("OPENCLAW_STATE_DIR", filepath.Join(s.home, ".openclaw"))), "openclaw.json")); os.IsNotExist(e) {
		return nil
	}
	exe, e := exec.LookPath("openclaw")
	if errors.Is(e, exec.ErrNotFound) {
		return nil
	}
	if e != nil {
		return e
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, exe, "status", "--usage", "--json")
	cmd.Env = append(cmd.Environ(), "OPENCLAW_STATE_DIR="+s.setting("openclaw", rootDir("OPENCLAW_STATE_DIR", filepath.Join(s.home, ".openclaw"))))
	buf := limitedBuffer{max: 8 << 20}
	cmd.Stdout = &buf
	cmd.Stderr = io.Discard
	if e = cmd.Run(); e != nil {
		return fmt.Errorf("OpenClaw quota query: %w", e)
	}
	var v struct {
		Usage struct {
			UpdatedAt int64
			Providers []struct {
				Provider string
				Windows  []struct {
					Label       string
					UsedPercent *float64
					ResetAt     int64
				}
			}
		}
	}
	// Some CLI versions emit plugin notices before the JSON document.
	raw := bytes.TrimSpace(buf.Bytes())
	for len(raw) > 0 {
		if raw[0] == '{' && json.Unmarshal(raw, &v) == nil {
			break
		}
		i := bytes.IndexByte(raw, '\n')
		if i < 0 {
			return errors.New("invalid OpenClaw status document")
		}
		raw = bytes.TrimSpace(raw[i+1:])
	}
	if len(v.Usage.Providers) == 0 {
		return nil
	}
	path := filepath.Join(s.dir, "openclaw-quota.json")
	var previous []Quota
	if e = loadOptional(path, &previous); e != nil {
		return e
	}
	byID := map[string]Quota{}
	for _, q := range previous {
		byID[q.Provider] = q
	}
	at := time.Now()
	if v.Usage.UpdatedAt > 0 {
		at = time.UnixMilli(v.Usage.UpdatedAt)
	}
	for _, p := range v.Usage.Providers {
		if strings.TrimSpace(p.Provider) == "" {
			continue
		}
		q := Quota{Provider: p.Provider, Observed: at.UTC().Format(time.RFC3339)}
		for _, w := range p.Windows {
			if w.UsedPercent == nil {
				continue
			}
			left := 100 - *w.UsedPercent
			reset := ""
			if w.ResetAt > 0 {
				reset = time.UnixMilli(w.ResetAt).UTC().Format(time.RFC3339)
			}
			q.Windows = append(q.Windows, Window{ID: w.Label, Label: w.Label, Remaining: &left, ResetAt: reset})
		}
		if len(q.Windows) > 0 {
			byID[p.Provider] = q
		}
	}
	out := []Quota{}
	for _, q := range byID {
		out = append(out, q)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Provider < out[j].Provider })
	return atomicJSON(path, out)
}
