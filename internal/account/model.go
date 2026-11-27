package account

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Provider is the account configuration shared with the desktop settings.
type Provider struct {
	ID           string       `json:"id"`
	Type         string       `json:"type"`
	DisplayName  string       `json:"displayName"`
	Enabled      bool         `json:"enabled"`
	Credential   *Credential  `json:"credential,omitempty"`
	Command      *Command     `json:"command,omitempty"`
	DatabasePath string       `json:"databasePath,omitempty"`
	Endpoint     string       `json:"endpoint,omitempty"`
	ManualUsage  *ManualUsage `json:"manualUsage,omitempty"`
	QuotaCache   *QuotaCache  `json:"quotaCache,omitempty"`
}
type Credential struct {
	EnvironmentVariable string `json:"environmentVariable,omitempty"`
	FilePath            string `json:"filePath,omitempty"`
}
type Command struct {
	Executable  string            `json:"executable"`
	Arguments   []string          `json:"arguments"`
	Environment map[string]string `json:"environment,omitempty"`
}
type ManualUsage struct {
	Status    string       `json:"status"`
	Label     string       `json:"label"`
	Used      *json.Number `json:"used,omitempty"`
	Remaining *json.Number `json:"remaining,omitempty"`
	Total     *json.Number `json:"total,omitempty"`
	Unit      string       `json:"unit,omitempty"`
	Message   string       `json:"message,omitempty"`
}
type QuotaCache struct {
	Directory  string `json:"directory"`
	ProviderID string `json:"providerId"`
}

type Environment struct {
	Home  string
	Force bool
}

type Snapshot struct {
	ProviderID     string          `json:"providerId"`
	DisplayName    string          `json:"displayName"`
	Status         string          `json:"status"`
	FetchedAt      string          `json:"fetchedAt"`
	Summary        string          `json:"summary,omitempty"`
	Message        string          `json:"message,omitempty"`
	Groups         []Group         `json:"groups"`
	ResetCredits   *ResetCredits   `json:"resetCredits,omitempty"`
	AccountCredits json.RawMessage `json:"accountCredits,omitempty"`
}
type Group struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Subtitle string   `json:"subtitle,omitempty"`
	Items    []Metric `json:"items"`
}
type Metric struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Kind      string `json:"kind"`
	Status    string `json:"status"`
	Detail    string `json:"detail,omitempty"`
	ResetText string `json:"resetText,omitempty"`
	ResetAt   string `json:"resetAt,omitempty"`
	// Quote vendor amounts as decimal strings so JSON consumers preserve their precision.
	UsedAmount            string   `json:"usedAmount,omitempty"`
	RemainingAmount       string   `json:"remainingAmount,omitempty"`
	TotalAmount           string   `json:"totalAmount,omitempty"`
	Unit                  string   `json:"unit,omitempty"`
	UsedPercent           *float64 `json:"usedPercent,omitempty"`
	RemainingPercent      *float64 `json:"remainingPercent,omitempty"`
	WindowDurationMinutes *int     `json:"windowDurationMinutes,omitempty"`
}
type ResetCredits struct {
	AvailableCount int           `json:"availableCount"`
	Credits        []ResetCredit `json:"credits"`
}
type ResetCredit struct {
	IssuedAt  string `json:"issuedAt,omitempty"`
	ExpiresAt string `json:"expiresAt,omitempty"`
}

func NewSnapshot(p Provider) Snapshot {
	return Snapshot{ProviderID: p.ID, DisplayName: p.DisplayName, Status: "ok", FetchedAt: time.Now().UTC().Format(time.RFC3339), Groups: []Group{}}
}

func resetCountdown(when, now time.Time) string {
	minutes := max(int(when.Sub(now).Minutes()), 0)
	switch {
	case minutes >= 24*60:
		return fmt.Sprintf("%dd%dh", minutes/(24*60), (minutes/60)%24)
	case minutes >= 60:
		return fmt.Sprintf("%dh%dm", minutes/60, minutes%60)
	default:
		return fmt.Sprintf("%dm", minutes)
	}
}

func billingPercent(id, label string, minutes int, used float64, resets, now time.Time) Metric {
	used = max(0, min(100, used))
	remaining := 100 - used
	m := Metric{ID: id, Label: label, Kind: "quota", Status: "ok", UsedPercent: &used, RemainingPercent: &remaining}
	if minutes > 0 {
		m.WindowDurationMinutes = &minutes
	}
	if !resets.IsZero() {
		m.ResetAt = resets.UTC().Format(time.RFC3339)
		m.ResetText = resetCountdown(resets, now)
	}
	return m
}

var decimalParts = regexp.MustCompile(`^([+-]?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$`)

// DecimalAmount retains every reported decimal digit, including integer counts above 2^53.
// Limit expansion before accepting an exponent from an external provider.
func DecimalAmount(value string) string {
	const maxDigits = 256
	if len(value) == 0 || len(value) > maxDigits {
		return ""
	}
	parts := decimalParts.FindStringSubmatch(value)
	if parts == nil {
		return ""
	}
	point := len(parts[2])
	if parts[4] != "" {
		shift, err := strconv.Atoi(parts[4])
		if err != nil || shift < -maxDigits || shift > maxDigits {
			return ""
		}
		point += shift
	}
	digits := parts[2] + parts[3]
	var whole, fraction string
	switch {
	case point <= 0:
		whole = "0"
		fraction = strings.Repeat("0", -point) + digits
	case point >= len(digits):
		whole = digits + strings.Repeat("0", point-len(digits))
	default:
		whole = digits[:point]
		fraction = digits[point:]
	}
	whole = strings.TrimLeft(whole, "0")
	if whole == "" {
		whole = "0"
	}
	if len(whole)+len(fraction) > maxDigits {
		return ""
	}
	if parts[1] == "-" {
		whole = "-" + whole
	}
	if fraction != "" {
		return whole + "." + fraction
	}
	return whole
}

func isoSeconds(value string) string {
	if value == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// The desktop's Codable snapshot uses non-null arrays and whole-second ISO dates.
func (s *Snapshot) normalize(p Provider) {
	s.ProviderID = p.ID
	if s.DisplayName == "" {
		s.DisplayName = p.DisplayName
	}
	if s.FetchedAt = isoSeconds(s.FetchedAt); s.FetchedAt == "" {
		s.FetchedAt = time.Now().UTC().Format(time.RFC3339)
	}
	if s.Groups == nil {
		s.Groups = []Group{}
	}
	for i := range s.Groups {
		group := &s.Groups[i]
		if group.Items == nil {
			group.Items = []Metric{}
		}
		for j := range group.Items {
			m := &group.Items[j]
			m.ResetAt = isoSeconds(m.ResetAt)
			m.UsedAmount = DecimalAmount(m.UsedAmount)
			m.RemainingAmount = DecimalAmount(m.RemainingAmount)
			m.TotalAmount = DecimalAmount(m.TotalAmount)
			m.Unit = strings.TrimSpace(m.Unit)
			if m.UsedAmount == "" && m.RemainingAmount == "" && m.TotalAmount == "" ||
				len(m.Unit) > 128 || strings.ContainsFunc(m.Unit, unicode.IsControl) {
				m.Unit = ""
			}
		}
	}
	if r := s.ResetCredits; r != nil {
		if r.Credits == nil {
			r.Credits = []ResetCredit{}
		}
		for i := range r.Credits {
			c := &r.Credits[i]
			c.IssuedAt = isoSeconds(c.IssuedAt)
			c.ExpiresAt = isoSeconds(c.ExpiresAt)
		}
	}
}
