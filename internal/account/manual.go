package account

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

func manualNumber(n *json.Number) *float64 {
	if n == nil {
		return nil
	}
	v, err := n.Float64()
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return nil
	}
	return &v
}

func collectManual(_ context.Context, _ Environment, p Provider) (Snapshot, error) {
	usage := p.ManualUsage
	if usage == nil {
		usage = &ManualUsage{Status: "unknown", Label: "用量"}
	}
	label := usage.Label
	if label == "" {
		label = "用量"
	}
	status := usage.Status
	switch status {
	case "ok", "warning", "error", "unknown":
	default:
		status = "unknown"
	}
	metric := Metric{ID: p.ID + "-" + label, Label: label, Kind: "quota", Status: status}
	metric.Detail = usage.Message
	if usage.Unit == "%" || usage.Unit == "" && usage.Total == nil {
		metric.UsedPercent, metric.RemainingPercent = manualNumber(usage.Used), manualNumber(usage.Remaining)
	} else {
		metric.Unit = usage.Unit
		var amounts []string
		for _, item := range []struct {
			name string
			n    *json.Number
			out  *string
		}{{"已用", usage.Used, &metric.UsedAmount}, {"剩余", usage.Remaining, &metric.RemainingAmount}, {"总额", usage.Total, &metric.TotalAmount}} {
			if item.n != nil {
				amounts = append(amounts, strings.TrimSpace(fmt.Sprintf("%s %s %s", item.name, item.n, usage.Unit)))
				*item.out = item.n.String()
			}
		}
		if metric.Detail != "" {
			amounts = append(amounts, metric.Detail)
		}
		metric.Detail = strings.Join(amounts, " · ")
		if total := manualNumber(usage.Total); total != nil && *total > 0 {
			asPercent := func(n *json.Number) *float64 {
				amount := manualNumber(n)
				if amount == nil {
					return nil
				}
				v := *amount / *total * 100
				if math.IsInf(v, 0) || math.IsNaN(v) {
					return nil
				}
				return &v
			}
			metric.UsedPercent, metric.RemainingPercent = asPercent(usage.Used), asPercent(usage.Remaining)
		}
	}
	if metric.UsedPercent == nil && metric.RemainingPercent != nil {
		used := 100 - *metric.RemainingPercent
		metric.UsedPercent = &used
	} else if metric.RemainingPercent == nil && metric.UsedPercent != nil {
		remaining := 100 - *metric.UsedPercent
		metric.RemainingPercent = &remaining
	}
	if usage.Unit == "tokens" && usage.Remaining == nil && usage.Total == nil {
		metric.Kind = "tokens"
	}
	snap := oneGroupSnapshot(p, status, metric.Detail, []Metric{metric})
	snap.Message = usage.Message
	return snap, nil
}

func oneGroupSnapshot(p Provider, status, summary string, metrics []Metric) Snapshot {
	snap := NewSnapshot(p)
	snap.Status, snap.Summary = status, summary
	snap.Groups = []Group{{ID: p.ID, Title: p.DisplayName, Items: metrics}}
	return snap
}

func remainingMetric(p Provider, label string, remaining float64) Metric {
	used := 100 - remaining
	return Metric{
		ID: p.ID + "-" + label, Label: label, Kind: "quota", Status: "ok",
		UsedPercent: &used, RemainingPercent: &remaining,
	}
}
