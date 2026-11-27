package account

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"
	"unicode"
)

const agyPayloadLimit = 512 << 10

// Normalized windows can be larger than the compact upstream JSON.
const agyStoredLimit = 4 * agyPayloadLimit

type agyBucket struct {
	Fraction *float64    `json:"fraction,omitempty"`
	Amount   json.Number `json:"amount,omitempty"`
	Unit     string      `json:"unit,omitempty"`
	ResetAt  string      `json:"resetAt,omitempty"`
}

type agyObservation struct {
	ObservedAt time.Time            `json:"observedAt"`
	Buckets    map[string]agyBucket `json:"buckets"`
}

func agyCache(home string) string {
	return filepath.Join(home, ".token-meter", "cache")
}

func agyReadingPath(home string) string {
	return filepath.Join(agyCache(home), "antigravity-quota.json")
}

func agyConnectionPath(home string) string {
	return filepath.Join(agyCache(home), "antigravity-statusline.json")
}

func agyReadJSON(path string, value any, limit int64) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	b, err := readLimited(f, limit)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, value)
}

func agyWritePrivate(path string, value any) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".tokenmeter-agy-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	enc := json.NewEncoder(file)
	enc.SetIndent("", "  ")
	err = enc.Encode(value)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func agyParse(data []byte, now time.Time) (*agyObservation, error) {
	var payload struct {
		Quota      map[string]json.RawMessage `json:"quota"`
		AgentState string                     `json:"agent_state"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	result := &agyObservation{now.UTC(), map[string]agyBucket{}}
	if payload.AgentState == "authenticating" {
		return result, nil
	}
	if payload.Quota == nil || (len(payload.Quota) == 0 && payload.AgentState == "initializing") {
		return nil, nil
	}
	for key, raw := range payload.Quota {
		var row struct {
			Fraction *float64        `json:"remaining_fraction"`
			Amount   json.Number     `json:"remaining_amount"`
			Unit     json.RawMessage `json:"unit"`
			ResetAt  string          `json:"reset_time"`
			Seconds  float64         `json:"reset_in_seconds"`
			Disabled bool            `json:"disabled"`
		}
		if key == "" || len(key) > 128 || json.Unmarshal(raw, &row) != nil || row.Disabled {
			continue
		}
		if row.Fraction != nil && (*row.Fraction < 0 || *row.Fraction > 1) {
			row.Fraction = nil
		}
		if strings.HasPrefix(row.Amount.String(), "-") || len(row.Amount.String()) > 128 {
			row.Amount = ""
		}
		if row.Fraction == nil && row.Amount == "" {
			continue
		}
		reset, err := time.Parse(time.RFC3339Nano, row.ResetAt)
		if err != nil || reset.Unix() <= 0 {
			reset = time.Time{}
			if row.Seconds > 0 && row.Seconds < float64(math.MaxInt64/int64(time.Second)) {
				reset = now.Add(time.Duration(row.Seconds * float64(time.Second)))
			}
		}
		bucket := agyBucket{Fraction: row.Fraction, Amount: row.Amount}
		if row.Amount != "" {
			var unit string
			_ = json.Unmarshal(row.Unit, &unit)
			unit = strings.TrimSpace(unit)
			if len(unit) <= 48 && strings.IndexFunc(unit, func(r rune) bool {
				return !unicode.IsLetter(r) && !unicode.IsDigit(r) && !strings.ContainsRune(" /._%-", r) && !unicode.Is(unicode.Sc, r)
			}) == -1 {
				bucket.Unit = unit
			}
		}
		if !reset.IsZero() {
			bucket.ResetAt = reset.UTC().Format(time.RFC3339)
		}
		result.Buckets[key] = bucket
	}
	return result, nil
}

func agyRead(home string) *agyObservation {
	var obs agyObservation
	if err := agyReadJSON(agyReadingPath(home), &obs, agyStoredLimit); err != nil || obs.ObservedAt.IsZero() || obs.Buckets == nil {
		return nil
	}
	return &obs
}

// Session callbacks can arrive while a background query is still running or after opt-out.
func agySave(home string, obs *agyObservation, started time.Time, coalesce bool) error {
	return agyWithLock(home, func() error {
		if _, err := os.Stat(agyConnectionPath(home)); err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if old := agyRead(home); old != nil {
			if old.ObservedAt.After(started) || (coalesce && obs.ObservedAt.Sub(old.ObservedAt) < 5*time.Minute && reflect.DeepEqual(old.Buckets, obs.Buckets)) {
				return nil
			}
		}
		return agyWritePrivate(agyReadingPath(home), obs)
	})
}

func agySnapshot(p Provider, obs *agyObservation, now time.Time, failure error) Snapshot {
	result := NewSnapshot(p)
	if result.DisplayName == "Antigravity" {
		result.DisplayName = "AGY"
	}
	grouped := map[string][]Metric{}
	if obs != nil {
		result.FetchedAt = obs.ObservedAt.UTC().Format(time.RFC3339)
		for key, b := range obs.Buckets {
			item := Metric{ID: key, Label: key, Kind: "quota", Status: "ok"}
			if reset, err := time.Parse(time.RFC3339Nano, b.ResetAt); err == nil && reset.Unix() > 0 {
				if !reset.After(now) {
					continue
				}
				item.ResetAt = reset.UTC().Format(time.RFC3339)
				item.ResetText = resetCountdown(reset, now)
			}
			group := key
			switch {
			case strings.HasSuffix(key, "-5h"):
				mins := 300
				group, item.Label, item.WindowDurationMinutes = strings.TrimSuffix(key, "-5h"), "5 小时", &mins
			case strings.HasSuffix(key, "-weekly"):
				mins := 10080
				group, item.Label, item.WindowDurationMinutes = strings.TrimSuffix(key, "-weekly"), "每周", &mins
			}
			if b.Fraction != nil && *b.Fraction >= 0 && *b.Fraction <= 1 {
				left := *b.Fraction * 100
				used := 100 - left
				item.RemainingPercent, item.UsedPercent = &left, &used
				if left == 0 {
					item.Status = "warning"
				}
			}
			if b.Amount != "" && !strings.HasPrefix(b.Amount.String(), "-") {
				item.RemainingAmount, item.Unit = b.Amount.String(), b.Unit
				if item.RemainingPercent == nil {
					item.Detail = strings.TrimSpace("剩余 " + item.RemainingAmount + " " + item.Unit)
				}
			}
			if item.RemainingPercent == nil && item.RemainingAmount == "" {
				continue
			}
			grouped[group] = append(grouped[group], item)
		}
	}
	for group, items := range grouped {
		title := map[string]string{"gemini": "Gemini", "3p": "Claude/GPT", "gemini-argon-wtu": "Gemini Argon WTU"}[group]
		if title == "" {
			title = group
		}
		sort.Slice(items, func(i, j int) bool {
			a, b := items[i].WindowDurationMinutes, items[j].WindowDurationMinutes
			if a != nil && (b == nil || *a != *b) {
				return b == nil || *a < *b
			}
			if a == nil && b != nil {
				return false
			}
			return items[i].ID < items[j].ID
		})
		result.Groups = append(result.Groups, Group{ID: group, Title: title, Items: items})
	}
	priority := func(id string) int {
		if id == "gemini" {
			return 0
		}
		if id == "3p" {
			return 1
		}
		return 2
	}
	sort.Slice(result.Groups, func(i, j int) bool {
		a, b := result.Groups[i].ID, result.Groups[j].ID
		if priority(a) != priority(b) {
			return priority(a) < priority(b)
		}
		return a < b
	})
	if failure != nil {
		result.Status = "warning"
		if len(result.Groups) == 0 {
			result.Status = "error"
		}
		result.Message = failure.Error()
	} else if len(result.Groups) == 0 {
		result.Status = "warning"
		result.Message = "等待 AGY 提供账户额度。"
	}
	return result
}

var (
	agyMissing     = errors.New("找不到 Antigravity CLI（agy）。")
	agySignIn      = errors.New("请在终端打开 agy，完成 Google 账号登录。")
	agyTimeout     = errors.New("Google 额度查询超时，稍后会自动重试。")
	agyUnavailable = errors.New("暂时无法读取 AGY 额度，稍后会自动重试。")
)

func agyQueryError(log string, timedOut bool) error {
	text := strings.ToLower(log)
	switch {
	case strings.Contains(text, "invalid_grant"):
		return agySignIn
	case strings.Contains(text, "token refresh failed due to network error"):
		return errors.New("暂时无法连接 Google 续期登录，稍后会自动重试。")
	case strings.Contains(text, "not currently available in your location"):
		return errors.New("Google 提示当前地区不支持 Antigravity。")
	case strings.Contains(text, "not eligible") || strings.Contains(text, "account ineligible:"):
		return errors.New("Google 提示当前账号暂不具备 Antigravity 使用资格。")
	case strings.Contains(text, "triggering interactive oauth") || strings.Contains(text, "authentication required") || strings.Contains(text, "not authenticated"):
		return agySignIn
	case timedOut:
		return agyTimeout
	default:
		return agyUnavailable
	}
}

func collectAntigravity(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	started := time.Now()
	previous := agyRead(e.Home)
	snapshot := agySnapshot(p, previous, started, nil)
	if !e.Force && previous != nil && !previous.ObservedAt.After(started) && started.Sub(previous.ObservedAt) < 5*time.Minute && (len(previous.Buckets) == 0 || len(snapshot.Groups) > 0) {
		return snapshot, nil
	}
	if _, err := os.Stat(agyConnectionPath(e.Home)); err != nil {
		return agySnapshot(p, previous, started, errors.New("AGY 额度接入尚未就绪，请检查 Antigravity 设置。")), nil
	}
	var onboarding struct {
		OnboardingComplete bool `json:"onboardingComplete"`
	}
	_ = agyReadJSON(filepath.Join(e.Home, ".gemini", "antigravity-cli", "cache", "onboarding.json"), &onboarding, 64<<10)
	if (previous == nil || len(previous.Buckets) == 0) && !onboarding.OnboardingComplete {
		return agySnapshot(p, previous, started, agySignIn), nil
	}
	executable, err := e.LookPath("agy")
	if err != nil {
		return agySnapshot(p, previous, started, agyMissing), nil
	}
	helper, err := os.Executable()
	if err != nil {
		return agySnapshot(p, previous, started, agyUnavailable), nil
	}
	observation, err := agyBackground(ctx, e, executable, helper, 18*time.Second)
	if ctx.Err() != nil {
		return Snapshot{}, ctx.Err()
	}
	if err == nil {
		if err = agySave(e.Home, observation, started, false); err != nil {
			err = agyUnavailable
		}
	}
	latest := agyRead(e.Home)
	if latest != nil && latest.ObservedAt.After(started) {
		err = nil
	}
	return agySnapshot(p, latest, time.Now(), err), nil
}

func agyDiagnostic(logPath string, timedOut bool) error {
	f, err := os.Open(logPath)
	if err != nil {
		return agyQueryError("", timedOut)
	}
	defer f.Close()
	log, _ := io.ReadAll(io.LimitReader(f, 128<<10))
	return agyQueryError(string(log), timedOut)
}
