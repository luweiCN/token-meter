package account

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type CodexResetResult struct {
	Status   string `json:"status"`
	Message  string `json:"message"`
	Consumed bool   `json:"-"`
}

func resetResult(status string) CodexResetResult {
	messages := map[string]string{
		"disabled": "自动使用已关闭", "paused": "已暂停自动使用", "waiting": "等待重置卡进入到期前 1 小时",
		"checking": "正在检查重置卡", "needsLogin": "需要有效的本机 Codex 登录状态", "missingDetails": "无法取得卡片明细，请更新 Codex CLI",
		"succeeded": "已自动使用重置卡", "nothingToReset": "当前用量暂时无需重置", "noCredit": "目标重置卡已不可用",
		"uncertain": "使用结果待确认，将核对同一次请求", "unavailable": "暂时无法检查，请确认网络与登录状态", "unsupportedCLI": "请更新 Codex CLI，当前版本不支持指定重置卡",
	}
	return CodexResetResult{Status: status, Message: messages[status]}
}
func quotaHash(raw json.RawMessage) string {
	// Match the sorted JSON fingerprint already stored by the desktop journal.
	var data map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	_ = dec.Decode(&data)
	filtered := map[string]any{}
	for _, k := range []string{"primary", "secondary", "rateLimitReachedType"} {
		if value, ok := data[k]; ok {
			filtered[k] = value
		}
	}
	b, _ := json.Marshal(filtered)
	return accountHash(b)
}
func resetUUID() string {
	id := [16]byte{}
	rand.Read(id[:])
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
}

type codexResetClaim struct{ account, credit, owner, key string }

func claimCodex(ctx context.Context, db *sql.DB, identity, credit, quota string, now time.Time) (*codexResetClaim, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var state, oldKey, oldQuota string
	var lease, updated float64
	creditHash := accountHash([]byte(credit))
	err = tx.QueryRowContext(ctx, "SELECT state, idempotency_key, quota_hash, lease_until, updated_at FROM codex_reset_redemptions WHERE account_hash=? AND credit_hash=?", identity, creditHash).Scan(&state, &oldKey, &oldQuota, &lease, &updated)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	t := float64(now.UnixNano()) / 1e9
	if state == "succeeded" || state == "noCredit" || lease > t || (state != "" && updated+60 > t) || (state == "nothingToReset" && oldQuota == quota) {
		return nil, nil
	}
	key := oldKey
	if state != "pending" || key == "" {
		key = resetUUID()
	}
	claim := &codexResetClaim{account: identity, credit: creditHash, owner: resetUUID(), key: key}
	_, err = tx.ExecContext(ctx, `INSERT INTO codex_reset_redemptions(account_hash,credit_hash,idempotency_key,state,quota_hash,owner,lease_until,updated_at)
		VALUES(?,?,?,'pending',?,?,?,?) ON CONFLICT(account_hash,credit_hash) DO UPDATE SET
		idempotency_key=excluded.idempotency_key,state='pending',quota_hash=excluded.quota_hash,owner=excluded.owner,lease_until=excluded.lease_until,updated_at=excluded.updated_at`, identity, creditHash, key, quota, claim.owner, t+120, t)
	if err != nil {
		return nil, err
	}
	return claim, tx.Commit()
}
func finishCodex(ctx context.Context, db *sql.DB, claim *codexResetClaim, outcome string, now time.Time) error {
	state := "pending"
	switch outcome {
	case "reset", "alreadyRedeemed":
		state = "succeeded"
	case "nothingToReset", "noCredit":
		state = outcome
	}
	result, err := db.ExecContext(ctx, "UPDATE codex_reset_redemptions SET state=?, lease_until=0, updated_at=? WHERE account_hash=? AND credit_hash=? AND idempotency_key=? AND owner=?", state, float64(now.UnixNano())/1e9, claim.account, claim.credit, claim.key, claim.owner)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err == nil && n != 1 {
		return errors.New("重置卡处理权已变化")
	}
	return err
}

type resetAccountClient interface {
	read(context.Context) (codexState, error)
	consume(ctx context.Context, identity, credit, key string, enabled func() bool) (string, error)
}

func runCodexReset(ctx context.Context, db *sql.DB, client resetAccountClient, allowed func() bool, clock func() time.Time) (CodexResetResult, error) {
	if !allowed() || ctx.Err() != nil {
		return resetResult("paused"), nil
	}
	state, err := client.read(ctx)
	if err != nil {
		return resetResult("unavailable"), err
	}
	if !allowed() || ctx.Err() != nil {
		return resetResult("paused"), nil
	}
	now := clock()
	if now.Sub(state.fetched).Abs() > time.Minute {
		return resetResult("unavailable"), nil
	}
	if state.identity == "" {
		return resetResult("needsLogin"), nil
	}
	cs := state.limits.ResetCredits
	if cs == nil || cs.Credits == nil {
		return resetResult("missingDetails"), nil
	}
	var selected *codexCredit
	if cs.AvailableCount != nil && *cs.AvailableCount > 0 {
		for i := range cs.Credits {
			c := &cs.Credits[i]
			if c.eligible(now) && (selected == nil || c.ExpiresAt < selected.ExpiresAt) {
				selected = c
			}
		}
	}
	if selected == nil {
		var last string
		err = db.QueryRowContext(ctx, "SELECT state FROM codex_reset_redemptions WHERE account_hash=? ORDER BY updated_at DESC LIMIT 1", state.identity).Scan(&last)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return resetResult("unavailable"), err
		}
		if last == "succeeded" {
			return resetResult("succeeded"), nil
		}
		return resetResult("waiting"), nil
	}
	claim, err := claimCodex(ctx, db, state.identity, selected.ID, quotaHash(state.limits.RateLimits), now)
	if err != nil {
		return resetResult("unavailable"), err
	}
	if claim == nil {
		var existing string
		err = db.QueryRowContext(ctx, "SELECT state FROM codex_reset_redemptions WHERE account_hash=? AND credit_hash=?", state.identity, accountHash([]byte(selected.ID))).Scan(&existing)
		switch existing {
		case "succeeded", "nothingToReset", "noCredit":
			return resetResult(existing), err
		}
		return resetResult("waiting"), err
	}
	if !allowed() || ctx.Err() != nil || !selected.eligible(clock()) {
		return resetResult("paused"), nil
	}
	outcome, reqErr := client.consume(ctx, state.identity, selected.ID, claim.key, allowed)
	// Once a request was sent, remember its key even if this process is
	// shutting down. A timed-out server may already have consumed the card.
	saveCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 4*time.Second)
	defer cancel()
	if err = finishCodex(saveCtx, db, claim, outcome, clock()); err != nil {
		return resetResult("uncertain"), err
	}
	if reqErr != nil {
		switch {
		case !allowed() || errors.Is(reqErr, context.Canceled):
			return resetResult("paused"), nil
		case errors.Is(reqErr, errCodexSchema):
			return resetResult("unsupportedCLI"), nil
		case errors.Is(reqErr, errCodexChanged):
			return resetResult("needsLogin"), nil
		case errors.Is(reqErr, errCodexIneligible):
			return resetResult("waiting"), nil
		default:
			return resetResult("uncertain"), reqErr
		}
	}
	if outcome == "reset" || outcome == "alreadyRedeemed" {
		result := resetResult("succeeded")
		result.Consumed = true
		return result, nil
	}
	return resetResult(outcome), nil
}

// CheckCodexReset is called only by the resident CLI. A fresh provider reading,
// the original SQLite journal and a last-moment permission check govern each
// request. Optionally supply the running node's pause predicate for a custom state directory.
func CheckCodexReset(ctx context.Context, home string, permitted ...func() bool) (CodexResetResult, error) {
	path := filepath.Join(home, ".token-meter", "tokenmeter.sqlite")
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return resetResult("disabled"), nil
	} else if err != nil {
		return resetResult("unavailable"), err
	}
	db, err := sql.Open("sqlite", sqliteFile(path)+"?mode=rw&_pragma=busy_timeout(4000)&_txlock=immediate")
	if err != nil {
		return resetResult("unavailable"), err
	}
	defer db.Close()
	enabled := func() (bool, error) {
		var value string
		err := db.QueryRowContext(ctx, "SELECT value_json FROM settings WHERE key='codex.resetCredits.autoRedeemEnabled'").Scan(&value)
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		return value == "1" || value == "true", err
	}
	on, err := enabled()
	if err != nil {
		return resetResult("unavailable"), err
	}
	if !on {
		return resetResult("disabled"), nil
	}
	allowed := func() bool {
		if ctx.Err() != nil {
			return false
		}
		if len(permitted) > 0 {
			if !permitted[0]() {
				return false
			}
		} else if _, err := os.Stat(filepath.Join(home, ".token-meter", "node", "index-paused")); !errors.Is(err, os.ErrNotExist) {
			return false
		}
		on, err := enabled()
		if err != nil || !on {
			return false
		}
		ps, err := Providers(home)
		if err != nil {
			return false
		}
		for _, p := range ps {
			if p.ID == "codex" && p.Type == "codex" && p.Enabled {
				return true
			}
		}
		return false
	}
	if !allowed() {
		return resetResult("paused"), nil
	}
	c, err := findCodex(Environment{Home: home})
	if err != nil {
		return resetResult("unavailable"), err
	}
	return runCodexReset(ctx, db, c, allowed, time.Now)
}
