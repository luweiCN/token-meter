package account

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"modernc.org/sqlite"
)

type collector func(context.Context, Environment, Provider) (Snapshot, error)

var collectors = map[string]collector{
	"antigravity":    collectAntigravity,
	"claudeCode":     collectClaude,
	"codex":          collectCodex,
	"commandCode":    collectCommandCode,
	"grok":           collectGrok,
	"manual":         collectManual,
	"opencodeGo":     collectOpenCodeGo,
	"opencodeSQLite": collectOpenCodeSQLite,
	"qoder":          collectQoder,
	"quotaCache":     collectQuotaCache,
	"shellCommand":   collectShellCommand,
	"zhipu":          collectZhipu,
}

// Refresh immediately polls the configured accounts. An empty provider ID selects all enabled accounts.
func Refresh(ctx context.Context, home, only string) error {
	return refresh(ctx, home, only, true, collectors)
}

// RefreshDue applies the user's refresh interval per account, including failed attempts.
func RefreshDue(ctx context.Context, home string) error {
	return refresh(ctx, home, "", false, collectors)
}

// The SQLite lock lives apart from the usage database, which stays readable and writable
// throughout slow vendor requests. A terminated collector releases the lock at process exit.
func beginRefresh(ctx context.Context, db *sql.DB) (*sql.Tx, error) {
	for {
		tx, err := db.BeginTx(ctx, nil)
		if err == nil {
			return tx, nil
		}
		var sq *sqlite.Error
		if !errors.As(err, &sq) || (sq.Code()&255 != 5 && sq.Code()&255 != 6) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(75 * time.Millisecond):
		}
	}
}

func refresh(ctx context.Context, home, only string, force bool, plugins map[string]collector) error {
	if !filepath.IsAbs(home) {
		return errors.New("额度服务需要绝对的用户目录")
	}
	requested := time.Now()
	cache := filepath.Join(home, ".token-meter", "cache")
	if err := os.MkdirAll(cache, 0700); err != nil {
		return err
	}
	path := filepath.Join(cache, "account-refresh.sqlite")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	db, err := sql.Open("sqlite", sqliteFile(path)+"?_txlock=immediate&_pragma=busy_timeout(200)")
	if err != nil {
		return err
	}
	defer db.Close()
	tx, err := beginRefresh(ctx, db)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "CREATE TABLE IF NOT EXISTS attempts(provider TEXT PRIMARY KEY, finished INTEGER NOT NULL, source_stamp INTEGER NOT NULL)"); err != nil {
		return err
	}
	config, err := readPreferences(ctx, home)
	if err != nil {
		return err
	}
	if err := reconcileAntigravity(home, only, config.providers); err != nil {
		// Other accounts, and previously observed AGY quota, remain usable if the
		// upstream terminal settings file is unavailable. Retry on the next tick.
		log.Printf("Antigravity 终端状态栏接入失败: %v", err)
	}
	path = snapshotPath(home)
	previous, err := loadSnapshots(path)
	if err != nil {
		var syntax *json.SyntaxError
		var typeError *json.UnmarshalTypeError
		if !errors.As(err, &syntax) && !errors.As(err, &typeError) && !errors.Is(err, errResponseSize) {
			return err
		}
		// The cache is rebuildable. A damaged cache requires all enabled accounts
		// even when a single account originally requested a manual refresh.
		only = ""
		force = true
		previous = nil
	}
	byID := make(map[string]Snapshot, len(previous))
	for _, s := range previous {
		byID[s.ProviderID] = s
	}
	// Record the stamp before fetching. If another terminal writes a status line
	// while providers are in flight, the next tick will consume that newer input.
	stamps := make(map[string]int64)
	for _, p := range config.providers {
		if p.Type == "antigravity" && p.Enabled {
			if info, err := os.Stat(agyReadingPath(home)); err == nil {
				stamps[p.ID] = info.ModTime().UnixNano()
			}
		}
	}
	pending, err := config.dueProviders(ctx, tx, only, byID, stamps, requested, force)
	if err != nil {
		return err
	}
	results := collectPending(ctx, Environment{Home: home, Force: force}, pending, byID, plugins)
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, s := range results {
		byID[s.ProviderID] = s
	}

	// An account can be disabled while its request is in flight.
	config, err = readPreferences(ctx, home)
	if err != nil {
		return err
	}
	current := make([]Snapshot, 0, len(config.providers))
	for _, p := range config.providers {
		if s, ok := byID[p.ID]; ok && p.Enabled {
			current = append(current, s)
		}
	}
	if len(results) > 0 || len(current) != len(previous) {
		if err = saveSnapshots(path, current); err != nil {
			return err
		}
	}
	now := time.Now().UnixNano()
	for _, s := range results {
		if _, err = tx.ExecContext(ctx, "INSERT INTO attempts(provider,finished,source_stamp) VALUES (?,?,?) ON CONFLICT(provider) DO UPDATE SET finished=excluded.finished,source_stamp=excluded.source_stamp", s.ProviderID, now, stamps[s.ProviderID]); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func reconcileAntigravity(home, only string, providers []Provider) error {
	selected := only == ""
	enabled := false
	for _, p := range providers {
		if p.Type == "antigravity" {
			selected = selected || only == p.ID
			enabled = enabled || p.Enabled
		}
	}
	if !selected {
		return nil
	}
	executable := ""
	if enabled {
		name := "token-meter"
		if runtime.GOOS == "windows" {
			name += ".exe"
		}
		executable = filepath.Join(home, ".token-meter", "node", "launcher", name)
		if info, err := os.Stat(executable); err != nil || !info.Mode().IsRegular() {
			executable, err = os.Executable()
			if err != nil {
				return err
			}
		}
	}
	return AntigravityHook(home, executable, enabled)
}

func (config preferences) dueProviders(ctx context.Context, tx *sql.Tx, only string, byID map[string]Snapshot, stamps map[string]int64, requested time.Time, force bool) ([]Provider, error) {
	matched := only == ""
	var pending []Provider
	for _, p := range config.providers {
		if only != "" && p.ID != only {
			continue
		}
		matched = true
		if !p.Enabled {
			if only != "" {
				return nil, fmt.Errorf("供应商 %s 的额度查询已关闭", p.ID)
			}
			continue
		}
		var finished, sourceStamp int64
		err := tx.QueryRowContext(ctx, "SELECT finished,source_stamp FROM attempts WHERE provider=?", p.ID).Scan(&finished, &sourceStamp)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		_, cached := byID[p.ID]
		age := time.Since(time.Unix(0, finished))
		if cached && sourceStamp == stamps[p.ID] && age >= 0 && (finished >= requested.UnixNano() || (!force && age < config.interval)) {
			continue
		}
		pending = append(pending, p)
	}
	if !matched {
		return nil, fmt.Errorf("未知额度供应商 %q", only)
	}
	return pending, nil
}

func collectPending(ctx context.Context, env Environment, pending []Provider, byID map[string]Snapshot, plugins map[string]collector) []Snapshot {
	results := make([]Snapshot, len(pending))
	var workers sync.WaitGroup
	work := make(chan int)
	for range min(4, len(pending)) {
		workers.Go(func() {
			for i := range work {
				p := pending[i]
				if ctx.Err() == nil {
					results[i] = collectAccount(ctx, env, p, byID[p.ID], plugins[p.Type])
				}
			}
		})
	}
	for i := range pending {
		work <- i
	}
	close(work)
	workers.Wait()
	return results
}

func collectAccount(ctx context.Context, env Environment, p Provider, previous Snapshot, fn collector) Snapshot {
	s := NewSnapshot(p)
	queryErr := errors.New("不支持的额度来源")
	if fn != nil {
		run, cancel := context.WithTimeout(ctx, 100*time.Second)
		s, queryErr = fn(run, env, p)
		cancel()
	}
	s.normalize(p)
	if queryErr != nil {
		if s.Status == "" || s.Status == "ok" {
			s.Status = "error"
		}
		if s.Message == "" {
			s.Message = accountError(p, queryErr)
		}
	} else if s.Status == "" {
		s.Status = "ok"
	}
	if p.Type == "antigravity" {
		// This provider receives independent live status-line observations and expires
		// individual buckets itself, including when opening the upstream CLI fails.
		return s
	}
	return mergeSnapshot(time.Now(), previous, s)
}

func accountError(p Provider, err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return p.DisplayName + " 额度查询超时"
	case errors.Is(err, context.Canceled):
		return p.DisplayName + " 额度查询已取消"
	}
	// Commands and HTTP client errors can contain complete URLs or stderr. Only
	// explicit, single-line provider diagnostics should enter a user-visible file.
	msg := strings.TrimSpace(err.Error())
	if msg == "" || len(msg) > 480 || strings.ContainsAny(msg, "\r\n") ||
		strings.Contains(msg, "://") || strings.Contains(strings.ToLower(msg), "bearer ") {
		return p.DisplayName + " 暂时无法读取额度"
	}
	return msg
}
