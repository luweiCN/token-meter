package main

import (
	"database/sql"
	"encoding/json"
	"time"
)

// Codex's completion projects one observed response. Its message snapshot can
// be very large and contains conversations, so select only the metering fields.
func (c catalog) clawCompletions(tx *sql.Tx, emit emitSample) error {
	cols, err := columns(tx, "trajectory_runtime_events")
	if err != nil || !cols["event_json"] {
		return err
	}
	rows, err := tx.Query(`SELECT event_json->>'$.data.threadId', event_json->>'$.data.turnId',
		coalesce(event_json->>'$.modelId',''), event_json->>'$.ts', event_json->'$.data.usage'
		FROM trajectory_runtime_events
		WHERE event_json->>'$.type'='model.completed' AND json_type(event_json,'$.data.threadId')='text'
		  AND json_type(event_json,'$.data.turnId')='text' AND json_type(event_json,'$.data.usage')='object'
		ORDER BY session_id,seq`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var thread, turn, model, stamp string
		var raw []byte
		if err := rows.Scan(&thread, &turn, &model, &stamp, &raw); err != nil {
			return err
		}
		key := clawTurnKey(thread, turn)
		if key == "" {
			continue
		}
		var u clawUsage
		if err := json.Unmarshal(raw, &u); err != nil {
			return err
		}
		at, err := time.Parse(time.RFC3339Nano, stamp)
		if err != nil {
			return err
		}
		x, err := c.clawUsageSample(digest("openclaw-codex-completion", thread, turn), model, at, u)
		if err != nil {
			return err
		}
		if x.tokens() == 0 && x.CostMicros == 0 {
			continue
		}
		x.clawTurn, x.clawRank = key, clawTrace
		if err := emit(x); err != nil {
			return err
		}
	}
	return rows.Err()
}
