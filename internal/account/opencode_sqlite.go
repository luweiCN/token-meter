package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"

	_ "modernc.org/sqlite"
)

func collectOpenCodeSQLite(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	if p.DatabasePath == "" {
		return Snapshot{}, errors.New("数据库路径缺失")
	}
	path, err := filepath.Abs(e.ExpandPath(p.DatabasePath))
	if err != nil {
		return Snapshot{}, errors.New("OpenCode 数据库路径无效")
	}
	db, err := sql.Open("sqlite", sqliteFile(path)+"?mode=ro&_pragma=busy_timeout(4000)&_pragma=query_only(1)")
	if err != nil {
		return Snapshot{}, errors.New("无法打开 OpenCode 用量数据库")
	}
	defer db.Close()
	var sessions, total int64
	const totals = `SELECT COUNT(*),
		COALESCE(SUM(tokens_input),0) + COALESCE(SUM(tokens_output),0) +
		COALESCE(SUM(tokens_cache_read),0) + COALESCE(SUM(tokens_cache_write),0) +
		COALESCE(SUM(tokens_reasoning),0)
		FROM session`
	if err := db.QueryRowContext(ctx, totals).Scan(&sessions, &total); err != nil {
		if ctx.Err() != nil {
			return Snapshot{}, ctx.Err()
		}
		return Snapshot{}, errors.New("无法读取 OpenCode SQLite 会话用量，请检查数据库路径和 session 表的 Token 字段")
	}
	short := strconv.FormatInt(total, 10)
	switch {
	case total >= 1_000_000:
		short = fmt.Sprintf("%.1fM", float64(total)/1_000_000)
	case total >= 1_000:
		short = fmt.Sprintf("%.1fK", float64(total)/1_000)
	}
	summary := fmt.Sprintf("%d sessions · %s tokens", sessions, short)
	metric := Metric{
		ID: p.ID + "-累计", Label: "累计", Kind: "tokens", Status: "ok",
		Detail: fmt.Sprintf("%d sessions · %d tokens", sessions, total), UsedAmount: strconv.FormatInt(total, 10), Unit: "tokens",
	}
	snapshot := oneGroupSnapshot(p, "ok", summary, []Metric{metric})
	snapshot.Message = summary
	return snapshot, nil
}
