package main

import (
	"database/sql"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

type hermesUsage struct {
	session, model, route, status     string
	at                                float64
	input, output, read, write, calls int64
	actual, estimated                 sql.NullFloat64
}

func (h hermesUsage) value() Counts {
	v := Counts{Input: h.input, Output: h.output, CacheRead: h.read, CacheWrite: h.write, Events: h.calls}
	switch {
	case h.actual.Valid && (h.actual.Float64 > 0 || h.status == "actual"):
		v.CostMicros = int64(math.Round(h.actual.Float64 * 1e6))
	case h.estimated.Valid && (h.estimated.Float64 > 0 || h.status == "free" || h.status == "included" || h.status == "known" || h.status == "estimated"):
		v.CostMicros = int64(math.Round(h.estimated.Float64 * 1e6))
	case v.tokens() > 0:
		v.UnknownCost = max(int64(1), h.calls)
	}
	return v
}
func hermesRows(db *sql.DB, table string, visit func(hermesUsage) error) error {
	cols, e := columns(db, table)
	if e != nil {
		return e
	}
	if len(cols) == 0 && table == "session_model_usage" {
		return nil
	}
	if !cols["input_tokens"] || !cols["output_tokens"] {
		return errors.New("unrecognized Hermes token schema")
	}
	field := func(k, def string) string {
		if cols[k] {
			return "coalesce(t." + k + "," + def + ")"
		}
		return def
	}
	session, timeExpr, from := "t.id", "t.started_at", "sessions t"
	var route []string
	if table == "session_model_usage" {
		session = "t.session_id"
		from = table + " t JOIN sessions s ON s.id=t.session_id"
		timeExpr = "s.started_at"
		for _, k := range []string{"billing_provider", "billing_base_url", "billing_mode", "task"} {
			route = append(route, field(k, "''"))
		}
	}
	routeExpr := "''"
	if len(route) > 0 {
		routeExpr = strings.Join(route, "||char(0)||")
	}
	fields := []string{session, field("model", "'unknown'"), routeExpr, timeExpr}
	for _, k := range []string{"input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "api_call_count"} {
		fields = append(fields, field(k, "0"))
	}
	fields = append(fields, field("actual_cost_usd", "NULL"), field("estimated_cost_usd", "NULL"), field("cost_status", "''"))
	rows, e := db.Query("SELECT " + strings.Join(fields, ",") + " FROM " + from)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var h hermesUsage
		if e = rows.Scan(&h.session, &h.model, &h.route, &h.at, &h.input, &h.output, &h.read, &h.write, &h.calls, &h.actual, &h.estimated, &h.status); e != nil {
			return e
		}
		if e = visit(h); e != nil {
			return e
		}
	}
	return rows.Err()
}
func hermesFile(path string, emit emitSample) error {
	db, e := readDB(path)
	if e != nil {
		return e
	}
	defer db.Close()
	// Keep both projections on one read snapshot across concurrent Hermes writes.
	if _, e = db.Exec("BEGIN"); e != nil {
		return e
	}
	defer db.Exec("ROLLBACK")
	totals := map[string]Counts{}
	save := func(h hermesUsage, id string, v Counts) error {
		if v.tokens() == 0 && v.Events == 0 && v.CostMicros == 0 {
			return nil
		}
		if h.at <= 0 {
			return fmt.Errorf("Hermes session missing start time")
		}
		return emit(sample{id: digest("hermes", h.session, id), day: time.Unix(int64(h.at), 0).In(time.Local).Format(time.DateOnly), agent: "hermes", model: h.model, Counts: v})
	}
	e = hermesRows(db, "session_model_usage", func(h hermesUsage) error {
		v := h.value()
		t := totals[h.session]
		t.add(v)
		totals[h.session] = t
		return save(h, "route\x00"+h.model+"\x00"+h.route, v)
	})
	if e != nil {
		return e
	}
	return hermesRows(db, "sessions", func(h hermesUsage) error {
		v := h.value()
		t := totals[h.session]
		v.Input = max(0, v.Input-t.Input)
		v.Output = max(0, v.Output-t.Output)
		v.CacheRead = max(0, v.CacheRead-t.CacheRead)
		v.CacheWrite = max(0, v.CacheWrite-t.CacheWrite)
		v.Events = max(0, v.Events-t.Events)
		v.CostMicros = max(0, v.CostMicros-t.CostMicros)
		if v.tokens() == 0 {
			v.UnknownCost = 0
		} else if v.UnknownCost > 0 {
			v.UnknownCost = max(int64(1), v.Events)
		}
		return save(h, "session", v)
	})
}
