package account

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

type codexCredit struct {
	ID        string
	ResetType string
	Status    string
	GrantedAt float64
	ExpiresAt float64
}

func (c codexCredit) eligible(now time.Time) bool {
	remaining := c.ExpiresAt - float64(now.UnixNano())/1e9
	return strings.TrimSpace(c.ID) != "" && c.ResetType == "codexRateLimits" && c.Status == "available" && remaining > 0 && remaining <= 3600
}

type codexCreditList struct {
	AvailableCount *int
	Credits        []codexCredit
}
type codexWindow struct {
	UsedPercent        json.RawMessage
	WindowDurationMins json.RawMessage
	ResetsAt           json.RawMessage
}
type codexLimit struct {
	LimitID   string
	LimitName string
	Primary   *codexWindow
	Secondary *codexWindow
	Credits   *struct {
		Balance    json.RawMessage
		Unlimited  bool
		HasCredits *bool
	}
}
type codexAccountLimits struct {
	RateLimits          json.RawMessage
	RateLimitsByLimitID map[string]*codexLimit
	ResetCredits        *codexCreditList `json:"rateLimitResetCredits"`
}
type codexState struct {
	limits   codexAccountLimits
	identity string
	fetched  time.Time
}

var decimalPattern = regexp.MustCompile(`^[+-]?[0-9]+(?:\.[0-9]+)?$`)

func codexBalance(l *codexLimit) (string, json.RawMessage) {
	if l == nil || l.Credits == nil {
		return "unavailable", nil
	}
	c := l.Credits
	if c.Unlimited {
		return "unlimited", nil
	}
	var balance string
	_ = json.Unmarshal(c.Balance, &balance)
	if decimalPattern.MatchString(balance) {
		v := strings.TrimPrefix(strings.TrimPrefix(balance, "+"), "-")
		integer, fraction, point := strings.Cut(v, ".")
		integer = strings.TrimLeft(integer, "0")
		if integer == "" {
			integer = "0"
		}
		v = integer
		if point {
			v += "." + fraction
		}
		if strings.HasPrefix(balance, "-") {
			v = "-" + v
		}
		return "amount", json.RawMessage(v)
	}
	if c.HasCredits != nil {
		if *c.HasCredits {
			return "available", nil
		}
		return "noCredits", nil
	}
	return "unavailable", nil
}
func codexWallet(kind string, value json.RawMessage) json.RawMessage {
	entry := map[string]any{}
	if value != nil {
		entry["_0"] = value
	}
	b, _ := json.Marshal(map[string]any{"codex": map[string]any{"_0": map[string]any{kind: entry}}})
	return b
}
func ccNumber(data json.RawMessage) (float64, bool) {
	if len(data) == 0 || string(data) == "null" {
		return 0, false
	}
	var n json.Number
	if json.Unmarshal(data, &n) != nil {
		return 0, false
	}
	value, err := n.Float64()
	return value, err == nil && !math.IsInf(value, 0) && !math.IsNaN(value)
}
func ccEpoch(n float64) string {
	if n <= 0 {
		return ""
	}
	return time.Unix(int64(n), 0).UTC().Format(time.RFC3339)
}
func ccSummary(groups []Group) string {
	var parts []string
	for _, g := range groups {
		for _, m := range g.Items {
			if m.RemainingPercent != nil {
				n := strconv.FormatFloat(math.Round(*m.RemainingPercent*10)/10, 'f', -1, 64)
				parts = append(parts, g.Title+" "+m.Label+" "+n+"%")
			}
		}
	}
	return strings.Join(parts, " · ")
}
func codexLabel(minutes int) string {
	switch {
	case minutes <= 0:
		return "额度"
	case minutes%1440 == 0:
		return fmt.Sprintf("%dd", minutes/1440)
	case minutes%60 == 0:
		return fmt.Sprintf("%dh", minutes/60)
	default:
		return fmt.Sprintf("%dm", minutes)
	}
}
func (s codexState) snapshot(provider Provider) (Snapshot, error) {
	out := NewSnapshot(provider)
	var main *codexLimit
	if len(s.limits.RateLimits) > 0 && json.Unmarshal(s.limits.RateLimits, &main) != nil {
		return out, errCodexRead
	}
	buckets := maps.Clone(s.limits.RateLimitsByLimitID)
	if buckets == nil {
		buckets = map[string]*codexLimit{}
	}
	mainID := "codex"
	if main != nil {
		if main.LimitID != "" {
			mainID = main.LimitID
		}
		if buckets[mainID] == nil {
			buckets[mainID] = main
		}
	}
	kind, value := codexBalance(buckets["codex"])
	if mainID == "codex" {
		if mk, mv := codexBalance(main); mk != "unavailable" {
			kind, value = mk, mv
		}
	}
	out.AccountCredits = codexWallet(kind, value)
	for id, b := range buckets {
		if b == nil {
			continue
		}
		title := b.LimitName
		if title == "" {
			words := strings.FieldsFunc(id, func(r rune) bool { return r == '_' })
			for i, w := range words {
				rs := []rune(w)
				rs[0] = unicode.ToUpper(rs[0])
				words[i] = string(rs)
			}
			title = strings.Join(words, " ")
		}
		g := Group{ID: id, Title: title}
		for _, slot := range []struct {
			name string
			w    *codexWindow
		}{{"primary", b.Primary}, {"secondary", b.Secondary}} {
			if slot.w == nil {
				continue
			}
			used, ok := ccNumber(slot.w.UsedPercent)
			if !ok {
				continue
			}
			duration, _ := ccNumber(slot.w.WindowDurationMins)
			reset, _ := ccNumber(slot.w.ResetsAt)
			var resets time.Time
			if reset > 0 {
				resets = time.Unix(int64(reset), 0)
			}
			minutes := int(duration)
			g.Items = append(g.Items, billingPercent(id+"-"+slot.name, codexLabel(minutes), minutes, used, resets, s.fetched))
		}
		if len(g.Items) > 0 {
			out.Groups = append(out.Groups, g)
		}
	}
	sort.Slice(out.Groups, func(i, j int) bool {
		a, b := out.Groups[i], out.Groups[j]
		if (a.ID == "codex") != (b.ID == "codex") {
			return a.ID == "codex"
		}
		if a.Title == b.Title {
			return a.ID < b.ID
		}
		return strings.ToLower(a.Title) < strings.ToLower(b.Title)
	})
	if cs := s.limits.ResetCredits; cs != nil && cs.AvailableCount != nil {
		r := ResetCredits{AvailableCount: max(0, *cs.AvailableCount), Credits: []ResetCredit{}}
		for _, c := range cs.Credits {
			if c.Status == "available" {
				r.Credits = append(r.Credits, ResetCredit{IssuedAt: ccEpoch(c.GrantedAt), ExpiresAt: ccEpoch(c.ExpiresAt)})
			}
		}
		out.ResetCredits = &r
	}
	if len(out.Groups) == 0 && kind == "unavailable" {
		return out, errors.New("Codex 响应中没有额度或积分数据")
	}
	out.Summary = ccSummary(out.Groups)
	return out, nil
}
func collectCodex(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	s := NewSnapshot(p)
	s.AccountCredits = codexWallet("unavailable", nil)
	program, err := findCodex(e)
	if err != nil {
		return s, err
	}
	state, err := program.read(ctx)
	if err != nil {
		return s, err
	}
	return state.snapshot(p)
}
