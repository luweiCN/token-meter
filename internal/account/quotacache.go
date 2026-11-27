package account

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

func collectQuotaCache(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	cfg := p.QuotaCache
	if cfg == nil || cfg.Directory == "" || cfg.ProviderID == "" {
		return Snapshot{}, errors.New("缓存配置缺失")
	}
	dir := e.ExpandPath(cfg.Directory)
	files, err := os.ReadDir(dir)
	if err != nil {
		return Snapshot{}, fmt.Errorf("无法读取 %s 的额度缓存目录", cfg.ProviderID)
	}
	var path string
	var newest time.Time
	for _, entry := range files {
		if err := ctx.Err(); err != nil {
			return Snapshot{}, err
		}
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !strings.HasPrefix(name, cfg.ProviderID+"-") {
			continue
		}
		candidate := filepath.Join(dir, name)
		stat, err := os.Stat(candidate)
		if os.IsNotExist(err) { // Cache writers can rotate a file during enumeration.
			continue
		}
		if err != nil {
			return Snapshot{}, fmt.Errorf("无法查看 %s 的额度缓存", cfg.ProviderID)
		}
		if stat.Mode().IsRegular() && (path == "" || stat.ModTime().After(newest)) {
			path, newest = candidate, stat.ModTime()
		}
	}
	if path == "" {
		return Snapshot{}, fmt.Errorf("未找到 %s quota 缓存", cfg.ProviderID)
	}
	file, err := os.Open(path)
	if err != nil {
		return Snapshot{}, fmt.Errorf("无法打开 %s 的额度缓存", cfg.ProviderID)
	}
	defer file.Close()
	stat, err := file.Stat()
	if err != nil {
		return Snapshot{}, err
	}
	data, err := readLimited(file, 8<<20)
	if err != nil {
		return Snapshot{}, err
	}
	var root any
	if err := json.Unmarshal(data, &root); err != nil {
		return Snapshot{}, errors.New("额度缓存的 JSON 格式无效")
	}
	metrics := cachedMetrics(root, p)
	if len(metrics) == 0 {
		return Snapshot{}, errors.New("quota 缓存中没有可展示的额度")
	}
	ids := map[string]bool{}
	parts := make([]string, 0, len(metrics))
	for i := range metrics {
		m := &metrics[i]
		base := m.ID
		for n := 2; ids[m.ID]; n++ {
			m.ID = fmt.Sprintf("%s-%d", base, n)
		}
		ids[m.ID] = true
		value := strings.TrimSuffix(strconv.FormatFloat(*m.RemainingPercent, 'f', 1, 64), ".0")
		parts = append(parts, m.Label+" "+value+"%")
	}
	snapshot := oneGroupSnapshot(p, "ok", strings.Join(parts, " · "), metrics)
	snapshot.FetchedAt = stat.ModTime().UTC().Format(time.RFC3339)
	snapshot.Message = snapshot.Summary
	return snapshot, nil
}

func cachedMetrics(value any, p Provider) []Metric {
	var out []Metric
	switch v := value.(type) {
	case []any:
		for _, child := range v {
			out = append(out, cachedMetrics(child, p)...)
		}
	case map[string]any:
		remaining, ok := v["percentRemaining"].(float64)
		if raw, isString := v["percentRemaining"].(string); isString {
			var err error
			remaining, err = strconv.ParseFloat(raw, 64)
			ok = err == nil && !math.IsNaN(remaining) && !math.IsInf(remaining, 0)
		}
		if ok {
			label, found := v["label"].(string)
			if !found {
				label, _ = v["name"].(string)
			}
			label = strings.Trim(label, ":：")
			if label == "" {
				label = "额度"
			}
			metric := remainingMetric(p, label, remaining)
			if raw, ok := v["resetTimeIso"].(string); ok {
				if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
					metric.ResetAt = t.UTC().Format(time.RFC3339)
				}
			}
			return []Metric{metric}
		}
		for _, k := range []string{"result", "data"} {
			if entries := cachedMetrics(v[k], p); len(entries) != 0 {
				return entries
			}
		}
		for _, k := range slices.Sorted(maps.Keys(v)) {
			if k != "result" && k != "data" {
				out = append(out, cachedMetrics(v[k], p)...)
			}
		}
	}
	return out
}
