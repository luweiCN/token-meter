package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type clawCodexCall struct {
	sample
	thread, turn, response string
	// The request and its legacy token_count projection share this identity.
	rolloutID string
	// Four billable dimensions in this turn, through this request. Complete
	// means every component is covered by observed requests up to this point.
	cumulative   Counts
	complete     bool
	reportedTurn bool
}

func (c clawCodexCall) tokenCounts() Counts {
	return Counts{Input: c.Input, Output: c.Output, CacheRead: c.CacheRead, CacheWrite: c.CacheWrite}
}

// A copied rollout can also exist in the user's own Codex home. Only the
// private backend belongs to OpenClaw, including on older logs without originator.
func isClawCodexRollout(path string) bool {
	name := filepath.Base(path)
	if !strings.HasPrefix(name, "rollout-") || filepath.Ext(name) != ".jsonl" {
		return false
	}
	for dir := filepath.Dir(path); dir != filepath.Dir(dir); dir = filepath.Dir(dir) {
		switch filepath.Base(dir) {
		case "sessions", "archived_sessions":
			home := filepath.Dir(dir)
			agent := filepath.Dir(home)
			return filepath.Base(home) == "codex-home" && filepath.Base(agent) == "agent" &&
				filepath.Base(filepath.Dir(filepath.Dir(agent))) == "agents"
		}
	}
	return false
}

type codexUsage struct {
	Input     int64 `json:"input_tokens"`
	Read      int64 `json:"cached_input_tokens"`
	ReadAlias int64 `json:"cache_read_input_tokens"`
	Write     int64 `json:"cache_write_input_tokens"`
	Output    int64 `json:"output_tokens"`
	Reasoning int64 `json:"reasoning_output_tokens"`
}

// Codex includes cache reads/writes in input, and reasoning in output.
type codexAmounts struct {
	Counts
	reasoning int64
}

func (u *codexUsage) amounts() (codexAmounts, bool) {
	if u == nil {
		return codexAmounts{}, false
	}
	read := max(u.Read, u.ReadAlias)
	if u.Read < 0 || u.ReadAlias < 0 || u.Write < 0 || read > u.Input || u.Write > u.Input-read || u.Reasoning < 0 || u.Reasoning > u.Output {
		return codexAmounts{}, false
	}
	c := Counts{Input: u.Input - read - u.Write, CacheRead: read, CacheWrite: u.Write, Output: u.Output}
	return codexAmounts{c, u.Reasoning}, c.valid()
}

func (v codexAmounts) delta(prev codexAmounts) (codexAmounts, bool) {
	c := Counts{Input: v.Input - prev.Input, CacheRead: v.CacheRead - prev.CacheRead, CacheWrite: v.CacheWrite - prev.CacheWrite, Output: v.Output - prev.Output}
	return codexAmounts{c, v.reasoning - prev.reasoning}, c.valid() && v.reasoning >= prev.reasoning
}

func (v codexAmounts) identity(thread, basis, qualifier string) string {
	return digest("openclaw", "codex-rollout", thread, basis, qualifier,
		strconv.FormatInt(v.Input, 10), strconv.FormatInt(v.CacheRead, 10), strconv.FormatInt(v.CacheWrite, 10),
		strconv.FormatInt(v.Output, 10), strconv.FormatInt(v.reasoning, 10))
}

type codexRolloutPayload struct {
	Type, ID, Originator, Model string
	Thread                      string `json:"thread_id"`
	Turn                        string `json:"turn_id"`
	Response                    string `json:"response_id"`
	Fork                        string `json:"forked_from_id"`
	Parent                      string `json:"parent_thread_id"`
	Source                      json.RawMessage
	ServiceTier                 string `json:"service_tier"`
	Settings                    *struct {
		ServiceTier string `json:"service_tier"`
	} `json:"thread_settings"`
	ModelInfo   *struct{ Slug string } `json:"model_info"`
	Usage       *codexUsage
	TurnTotal   *codexUsage `json:"turn_token_usage"`
	ThreadTotal *codexUsage `json:"thread_token_usage"`
	Info        *struct {
		Model string
		Last  *codexUsage `json:"last_token_usage"`
		Total *codexUsage `json:"total_token_usage"`
	}
}

type codexTurnState struct {
	model, counterEpoch string
	observed            Counts
	started, continuous bool
}

type codexRollout struct {
	catalog
	thread, turn, tier         string
	counterEpoch               string
	fork, replayMeta, rejected bool
	sawMeta, ownerMeta         bool
	standalone                 bool
	previous                   codexAmounts
	havePrevious               bool
	inherited                  *codexAmounts
	turns                      map[string]*codexTurnState
	calls                      []clawCodexCall
	byResponse, byRollout      map[string]int
	paired                     int // 1-based index of the immediately preceding explicit request.
}

func (s *codexRollout) turnState(id string) *codexTurnState {
	t := s.turns[id]
	if t == nil {
		t = &codexTurnState{counterEpoch: s.counterEpoch}
		s.turns[id] = t
	}
	return t
}

func codexUUIDTime(id string) (int64, bool) {
	if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[14] != '7' || id[18] != '-' || id[23] != '-' {
		return 0, false
	}
	n, err := strconv.ParseInt(id[:8]+id[9:13], 16, 64)
	return n, err == nil
}

func (s *codexRollout) session(p codexRolloutPayload) {
	if p.ID == "" {
		return
	}
	s.sawMeta = true
	if s.thread != "" && p.ID != s.thread {
		// Forked files contain parent session_meta and parent turns before the
		// child's own first turn. Its actual thread identity never changes.
		s.replayMeta, s.turn = true, ""
		return
	}
	s.thread = p.ID
	s.ownerMeta = true
	if (s.standalone && p.Originator == "openclaw") ||
		(!s.standalone && p.Originator != "" && p.Originator != "openclaw") {
		s.rejected = true
	}
	var source struct {
		Subagent *struct {
			ThreadSpawn *struct {
				Parent string `json:"parent_thread_id"`
			} `json:"thread_spawn"`
		}
	}
	if len(p.Source) > 0 && p.Source[0] == '{' {
		_ = json.Unmarshal(p.Source, &source)
	}
	s.fork = s.fork || p.Fork != "" || p.Parent != "" || (source.Subagent != nil && source.Subagent.ThreadSpawn != nil && source.Subagent.ThreadSpawn.Parent != "")
	s.replayMeta = false
}

func (s *codexRollout) ownTurn(id string, confirmedStart bool) bool {
	if id == "" {
		return false
	}
	if !s.fork && !s.replayMeta {
		return true
	}
	birth, haveBirth := codexUUIDTime(s.thread)
	start, haveStart := codexUUIDTime(id)
	if haveBirth && haveStart {
		return start > birth || (start == birth && (!s.replayMeta || confirmedStart))
	}
	return !s.replayMeta
}

func (s *codexRollout) line(kind, stamp string, ordinal *int64, p codexRolloutPayload) error {
	paired := s.paired
	s.paired = 0
	switch kind {
	case "session_meta":
		s.session(p)
		return nil
	case "turn_context":
		if p.Turn != "" {
			if !s.ownTurn(p.Turn, false) {
				s.turn = ""
				return nil
			}
			s.turn = p.Turn
			s.replayMeta = false
		}
		if p.ModelInfo != nil && p.ModelInfo.Slug != "" {
			p.Model = p.ModelInfo.Slug
		}
		if p.Model != "" {
			s.turnState(s.turn).model = p.Model
		}
		return nil
	case "event_msg":
		switch p.Type {
		case "task_started":
			if s.ownTurn(p.Turn, true) {
				s.turn, s.replayMeta = p.Turn, false
				t := s.turnState(s.turn)
				if !t.started {
					t.started, t.continuous = true, t.observed == (Counts{})
				}
			}
			return nil
		case "item_completed":
			if s.turn == "" && s.ownTurn(p.Turn, false) {
				s.turn = p.Turn
			}
			return nil
		case "task_complete", "task_aborted", "turn_aborted":
			if p.Turn == "" || p.Turn == s.turn {
				s.turn = ""
			}
			return nil
		case "token_count":
			if p.Info == nil {
				return nil
			}
			p.Usage, p.ThreadTotal = p.Info.Last, p.Info.Total
			if p.Model == "" {
				p.Model = p.Info.Model
			}
		case "thread_settings_applied":
			kind = p.Type
		default:
			return nil
		}
	}
	if kind == "thread_settings_applied" {
		if p.Settings != nil {
			p.ServiceTier = p.Settings.ServiceTier
		}
		s.tier = p.ServiceTier
		return nil
	}
	if kind != "event_msg" && kind != "token_usage_record" {
		return nil
	}
	return s.usage(kind == "token_usage_record", stamp, ordinal, p, paired)
}

func (s *codexRollout) usage(explicit bool, stamp string, ordinal *int64, p codexRolloutPayload, paired int) error {
	if s.thread == "" {
		s.thread = p.Thread
	}
	if s.thread == "" || (p.Thread != "" && p.Thread != s.thread) {
		return nil
	}
	total, hasTotal := p.ThreadTotal.amounts()
	last, hasLast := p.Usage.amounts()
	turnTotal, hasTurnTotal := p.TurnTotal.amounts()
	if (p.ThreadTotal != nil && !hasTotal) || (p.Usage != nil && !hasLast) || (p.TurnTotal != nil && !hasTurnTotal) {
		return errors.New("invalid Codex token counts")
	}
	turn := p.Turn
	if turn == "" {
		turn = s.turn
	}
	if (s.fork || s.replayMeta) && !s.ownTurn(turn, explicit && p.Thread == s.thread) {
		if hasTotal {
			s.previous, s.havePrevious = total, true
			s.inherited = &total
		}
		return nil
	}
	if s.inherited != nil && hasTotal {
		if _, within := s.inherited.delta(total); within && !(explicit && p.Thread == s.thread && p.Response != "") {
			return nil
		}
		s.inherited = nil
	}
	t := s.turnState(turn)
	if hasTotal && total == (codexAmounts{}) && (!hasLast || last == (codexAmounts{})) {
		if p.Turn != "" && p.Turn == s.turn && t.started && t.observed == (Counts{}) {
			if s.havePrevious && s.previous.tokens() > 0 {
				// The new task explicitly reported a zero thread counter. Its
				// following requests may reuse an earlier turn's cumulative tuple.
				s.counterEpoch, t.counterEpoch = turn, turn
			}
			s.previous, s.havePrevious, t.continuous = total, true, true
		} else if !s.havePrevious {
			s.previous, s.havePrevious = total, true
		}
		return nil
	}
	var key string
	if hasTotal {
		key = total.identity(s.thread, "total", t.counterEpoch)
	} else if p.Response == "" && hasLast {
		if ordinal != nil {
			key = last.identity(s.thread, "ordinal", turn+"\x00"+strconv.FormatInt(*ordinal, 10))
		} else if when, err := time.Parse(time.RFC3339Nano, stamp); err == nil {
			key = last.identity(s.thread, "last", turn+"\x00"+strconv.FormatInt(when.UnixMilli(), 10))
		}
	}
	i, found := s.byRollout[key]
	// A reset can reuse a cumulative tuple. Two distinct provider response IDs
	// remain distinct even then; only one can claim that legacy alias.
	if found && p.Response != "" && s.calls[i].response != "" && s.calls[i].response != p.Response {
		key, found = "", false
	}
	if p.Response != "" {
		if j, ok := s.byResponse[p.Response]; ok {
			i, found = j, true
		}
	}
	if !found && !explicit && paired != 0 && hasLast {
		prior := s.calls[paired-1]
		// Newer backends emit a status snapshot immediately after their request.
		// Without a common thread total, adjacency + identical usage ties the pair.
		if prior.turn == turn && (prior.rolloutID == "" || !hasTotal) &&
			prior.Input == last.Input && prior.Output == last.Output && prior.CacheRead == last.CacheRead && prior.CacheWrite == last.CacheWrite {
			i, found = paired-1, true
		}
	}
	if found {
		call := &s.calls[i]
		if explicit && call.response == "" && hasLast && p.Response != "" {
			at, err := time.Parse(time.RFC3339Nano, stamp)
			if err != nil {
				return fmt.Errorf("Codex usage timestamp: %w", err)
			}
			canonical, err := s.clawUsageSample(digest("openclaw", "openai", p.Response), call.model, at,
				clawUsage{Input: last.Input, Output: last.Output, CacheRead: last.CacheRead, CacheWrite: last.CacheWrite})
			if err != nil {
				return err
			}
			corrected := call.tokenCounts() != last.Counts
			call.sample = canonical
			if hasTurnTotal {
				call.complete = turn != "" && call.cumulative == turnTotal.Counts
				call.cumulative, call.reportedTurn = turnTotal.Counts, true
			}
			if corrected {
				// A legacy status can precede its authoritative request. Replace
				// that delta before testing any later official turn totals.
				var prefix Counts
				for j := range s.calls {
					row := &s.calls[j]
					if row.turn != call.turn {
						continue
					}
					var ok bool
					prefix, ok = prefix.checkedSum(row.tokenCounts())
					if !ok {
						return errors.New("Codex turn token counts exceed supported range")
					}
					if j < i {
						continue
					}
					if row.reportedTurn {
						row.complete = row.turn != "" && row.cumulative == prefix
					} else {
						row.cumulative, row.complete = prefix, false
					}
					t.continuous = row.complete
				}
				t.observed = prefix
			}
		}
		if p.Response != "" {
			call.response, call.id = p.Response, digest("openclaw", "openai", p.Response)
			s.byResponse[p.Response] = i
			s.paired = i + 1
		}
		if hasTotal && call.rolloutID == "" {
			call.rolloutID, s.byRollout[key] = key, i
			if i == len(s.calls)-1 {
				s.previous, s.havePrevious = total, true
			}
		}
		if key != "" {
			s.byRollout[key] = i
		}
		return nil
	}
	diff, monotonic := total.delta(s.previous)
	continuous := hasTotal && monotonic && (s.havePrevious || hasLast) && (!hasLast || diff == last)
	if hasTotal {
		if s.havePrevious && total == s.previous && p.Response == "" {
			return nil
		}
		if !explicit && hasLast && s.havePrevious && !monotonic && !(t.started && t.observed == (Counts{}) && total == last) {
			// A stale status frame can be copied after resume. A fresh task may
			// restart the counters at its first request's usage.
			return nil
		}
		if !hasLast {
			if !s.havePrevious || !monotonic {
				// The first snapshot of an already-running thread can include many
				// earlier turns. Establish a baseline before charging any delta.
				s.previous, s.havePrevious = total, true
				t.continuous = false
				return nil
			}
			last = diff
		}
		s.previous, s.havePrevious = total, true
	} else if !hasLast {
		return nil
	} else {
		s.havePrevious = false
	}
	if last.tokens() == 0 {
		return nil
	}
	at, err := time.Parse(time.RFC3339Nano, stamp)
	if err != nil {
		return fmt.Errorf("Codex usage timestamp: %w", err)
	}
	model := p.Model
	if model == "" {
		model = t.model
	} else {
		t.model = model
	}
	if model == "" {
		model = "unknown"
	}
	if (s.tier == "fast" || s.tier == "priority") && !strings.HasSuffix(model, "-fast") {
		model += "-fast"
	}
	amounts, ok := t.observed.checkedSum(last.Counts)
	if !ok {
		return errors.New("Codex turn token counts exceed supported range")
	}
	t.observed, t.continuous = amounts, t.continuous && continuous
	complete := turn != "" && t.continuous
	if hasTurnTotal {
		complete = turn != "" && turnTotal.Counts == amounts
		amounts = turnTotal.Counts
		t.continuous = complete
	}
	usage, err := s.clawUsageSample(key, model, at, clawUsage{Input: last.Input, Output: last.Output, CacheRead: last.CacheRead, CacheWrite: last.CacheWrite})
	if err != nil {
		return err
	}
	call := clawCodexCall{
		sample: usage,
		thread: s.thread, turn: turn, response: p.Response, rolloutID: key, cumulative: amounts, complete: complete, reportedTurn: hasTurnTotal,
	}
	index := len(s.calls)
	if key != "" {
		s.byRollout[key] = index
	}
	if p.Response != "" {
		call.id = digest("openclaw", "openai", p.Response)
		s.byResponse[p.Response] = index
		s.paired = index + 1
	}
	s.calls = append(s.calls, call)
	return nil
}

func (c catalog) clawCodexRollout(path string, emit func(clawCodexCall) error) error {
	if !isClawCodexRollout(path) {
		return nil
	}
	return c.readCodexRollout(path, false, emit)
}

func (c catalog) readCodexRollout(path string, standalone bool, emit func(clawCodexCall) error) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	s := codexRollout{catalog: c, standalone: standalone, turns: map[string]*codexTurnState{}, byResponse: map[string]int{}, byRollout: map[string]int{}}
	name := strings.TrimSuffix(filepath.Base(path), ".jsonl")
	if len(name) >= 36 {
		id := name[len(name)-36:]
		if _, ok := codexUUIDTime(id); ok {
			s.thread = id
		}
	}
	reader := bufio.NewReaderSize(f, 64*1024)
	for {
		raw, e := reader.ReadBytes('\n')
		if e != nil && e != io.EOF {
			return e
		}
		if len(bytes.TrimSpace(raw)) != 0 {
			var r struct {
				Type    string
				Payload struct{ Type string }
			}
			if err := json.Unmarshal(raw, &r); err != nil {
				if e == io.EOF {
					break
				}
				return err
			}
			metering := false
			switch r.Type {
			case "session_meta", "turn_context", "thread_settings_applied", "token_usage_record":
				metering = true
			case "event_msg":
				switch r.Payload.Type {
				case "token_count", "task_started", "task_complete", "task_aborted", "turn_aborted", "thread_settings_applied":
					metering = true
				case "item_completed":
					metering = s.turn == ""
				}
			}
			if metering {
				var row struct {
					Timestamp string
					Ordinal   *int64
					Payload   codexRolloutPayload
				}
				if err := json.Unmarshal(raw, &row); err != nil {
					return err
				}
				if err := s.line(r.Type, row.Timestamp, row.Ordinal, row.Payload); err != nil {
					return err
				}
				if s.rejected {
					return nil
				}
			} else {
				s.paired = 0
			}
		}
		if e == io.EOF {
			break
		}
	}
	if s.sawMeta && !s.ownerMeta {
		return nil
	}
	for _, call := range s.calls {
		if err := emit(call); err != nil {
			return err
		}
	}
	return nil
}
