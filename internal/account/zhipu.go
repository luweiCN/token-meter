package account

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

func collectZhipu(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	u, err := billingURL(p.Endpoint)
	if err != nil {
		return Snapshot{}, err
	}
	key := selectedBillingKey(ctx, e, p)
	if key == "" {
		return Snapshot{}, errors.New("缺少智谱 API Key")
	}
	raw, _, err := billingGET(ctx, billingClient, u, http.Header{"Authorization": {key}}, p.DisplayName)
	if err != nil {
		return Snapshot{}, err
	}
	return parseZhipu(p, raw, time.Now())
}

func billingValue(value any) (float64, bool) {
	switch v := value.(type) {
	case json.Number:
		n, err := v.Float64()
		return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0)
	case string:
		n, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0)
	}
	return 0, false
}

func zhipuAmount(value any) string {
	switch n := value.(type) {
	case json.Number:
		return DecimalAmount(n.String())
	case string:
		return DecimalAmount(strings.TrimSpace(n))
	}
	return ""
}

func parseZhipu(p Provider, raw []byte, now time.Time) (Snapshot, error) {
	var root map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&root) != nil || root == nil || decoder.Decode(new(any)) != io.EOF {
		return Snapshot{}, errors.New("智谱额度响应格式错误")
	}
	if success, ok := root["success"].(bool); ok && !success {
		// The response is also cached and synchronized. Do not retain a vendor's error body that might echo a key.
		code, _ := billingValue(root["code"])
		if message, ok := root["msg"].(string); ok && message == "身份验证失败。" {
			return Snapshot{}, errors.New(message)
		}
		switch int(code) {
		case 1000, 1001, 1002, 1003, 1004:
			return Snapshot{}, errors.New("智谱身份验证失败，请检查 API Key")
		default:
			if code > 0 {
				return Snapshot{}, fmt.Errorf("智谱额度查询失败（业务代码 %d）", int(code))
			}
			return Snapshot{}, errors.New("智谱接口返回业务失败")
		}
	}
	data, _ := root["data"].(map[string]any)
	limits, ok := data["limits"].([]any)
	if !ok {
		return parseZhipuBalance(p, root)
	}
	type window struct {
		id, label string
		minutes   int
	}
	spec := []window{{"zhipu-5h", "5h", 300}, {"zhipu-7d", "7d", 10080}, {"zhipu-mcp", "MCP", 0}}
	var byWindow [3]*Metric
	for _, item := range limits {
		row, _ := item.(map[string]any)
		percent, valid := billingValue(row["percentage"])
		unit, unitOK := billingValue(row["unit"])
		if !unitOK {
			continue
		}
		var index int
		switch {
		case row["type"] == "TOKENS_LIMIT" && unit == 3:
			index = 0
		case row["type"] == "TOKENS_LIMIT" && unit == 6:
			index = 1
		case row["type"] == "TIME_LIMIT" && unit == 5:
			index = 2
		default:
			continue
		}
		var reset time.Time
		if ms, ok := billingValue(row["nextResetTime"]); ok && ms > 0 {
			reset = time.UnixMilli(int64(ms))
		}
		w := spec[index]
		m := Metric{ID: w.id, Label: w.label, Kind: "quota", Status: "ok"}
		if valid {
			m = billingPercent(w.id, w.label, w.minutes, percent, reset, now)
		} else if !reset.IsZero() {
			m.ResetAt, m.ResetText = reset.UTC().Format(time.RFC3339), resetCountdown(reset, now)
		}
		if index == 2 {
			m.UsedAmount = zhipuAmount(row["currentValue"])
			m.TotalAmount = zhipuAmount(row["usage"])
			m.RemainingAmount = zhipuAmount(row["remaining"])
			if m.UsedAmount != "" || m.TotalAmount != "" || m.RemainingAmount != "" {
				m.Unit = "次"
			}
			switch {
			case m.UsedAmount != "" && m.TotalAmount != "":
				m.Detail = m.UsedAmount + "/" + m.TotalAmount + " 次"
			case m.RemainingAmount != "":
				m.Detail = "剩余 " + m.RemainingAmount + " 次"
			case m.UsedAmount != "":
				m.Detail = "已用 " + m.UsedAmount + " 次"
			case m.TotalAmount != "":
				m.Detail = "总额 " + m.TotalAmount + " 次"
			}
		}
		if !valid && m.Unit == "" {
			continue
		}
		byWindow[index] = &m
	}
	items := []Metric{}
	for _, m := range byWindow {
		if m != nil {
			items = append(items, *m)
		}
	}
	if len(items) == 0 {
		return Snapshot{}, errors.New("智谱响应中没有可用的额度字段")
	}
	s := NewSnapshot(p)
	s.Groups = []Group{{ID: "zhipu-coding-plan", Title: p.DisplayName, Items: items}}
	s.Summary = billingSummary(items)
	if s.Summary == "" {
		s.Summary = items[0].Label + " " + items[0].Detail
	}
	return s, nil
}

type zhipuBalance struct{ used, remaining, total, percent, currency string }

// Resolve amounts from one account object so separate wallets cannot donate a currency or a total to each other.
func zhipuBalanceRow(value any, currency string) *zhipuBalance {
	switch row := value.(type) {
	case map[string]any:
		for _, name := range []string{"currency", "currencyCode", "currency_code", "unit"} {
			if text, ok := row[name].(string); ok && strings.TrimSpace(text) != "" {
				switch strings.ToUpper(strings.TrimSpace(text)) {
				case "CNY", "RMB":
					currency = "CNY"
				case "USD":
					currency = "USD"
				default:
					currency = ""
				}
				break
			}
		}
		first := func(names ...string) string {
			for _, name := range names {
				if n := zhipuAmount(row[name]); n != "" {
					return n
				}
			}
			return ""
		}
		b := zhipuBalance{
			used:      first("used", "used_quota", "usedQuota", "usage"),
			remaining: first("remaining", "remain", "remain_quota", "remaining_quota", "available"),
			total:     first("total", "total_quota", "totalQuota", "limit"),
			percent:   first("percentage"), currency: currency,
		}
		if b.used != "" || b.remaining != "" || b.total != "" {
			return &b
		}
		keys := make([]string, 0, len(row))
		for k := range row {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if found := zhipuBalanceRow(row[k], currency); found != nil {
				if found.percent == "" {
					found.percent = b.percent
				}
				return found
			}
		}
		if b.percent != "" {
			return &b
		}
	case []any:
		for _, item := range row {
			if found := zhipuBalanceRow(item, currency); found != nil {
				return found
			}
		}
	}
	return nil
}

func parseZhipuBalance(p Provider, root map[string]any) (Snapshot, error) {
	b := zhipuBalanceRow(root, "")
	if b == nil {
		return Snapshot{}, errors.New("智谱响应中没有可用的额度字段")
	}
	m := Metric{ID: p.ID + "-余额", Label: "余额", Kind: "balance", Status: "ok"}
	used, hasUsed := billingValue(b.used)
	remaining, hasRemaining := billingValue(b.remaining)
	total, hasTotal := billingValue(b.total)
	percent, hasPercent := billingValue(b.percent)
	if !hasPercent && hasTotal && total > 0 {
		switch {
		case hasRemaining:
			percent, hasPercent = (total-remaining)/total*100, true
		case hasUsed:
			percent, hasPercent = used/total*100, true
		}
	}
	if hasPercent {
		m = billingPercent(m.ID, m.Label, 0, percent, time.Time{}, time.Now())
		m.Kind = "balance"
	}
	if b.used != "" || b.remaining != "" || b.total != "" {
		m.UsedAmount, m.RemainingAmount, m.TotalAmount, m.Unit = b.used, b.remaining, b.total, b.currency
	}
	var parts []string
	for _, amount := range []struct{ label, value string }{{"已用", b.used}, {"剩余", b.remaining}, {"总额", b.total}} {
		if amount.value != "" {
			parts = append(parts, strings.TrimSpace(amount.label+" "+amount.value+" "+b.currency))
		}
	}
	m.Detail = strings.Join(parts, " · ")
	s := NewSnapshot(p)
	s.Groups = []Group{{ID: p.ID, Title: p.DisplayName, Items: []Metric{m}}}
	s.Summary = m.Detail
	if s.Summary == "" {
		s.Summary = billingSummary([]Metric{m})
	}
	return s, nil
}
