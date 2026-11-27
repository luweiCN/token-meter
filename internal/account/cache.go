package account

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const maxSnapshotSize = 16 << 20

func snapshotPath(home string) string {
	return filepath.Join(home, ".token-meter", "cache", "provider-snapshots.json")
}

// Read returns the latest local observations without contacting a vendor.
func Read(home string) ([]Snapshot, error) {
	return loadSnapshots(snapshotPath(home))
}

func loadSnapshots(path string) ([]Snapshot, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return []Snapshot{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := readLimited(f, maxSnapshotSize)
	if err != nil {
		return nil, err
	}
	var snapshots []Snapshot
	err = json.Unmarshal(data, &snapshots)
	return snapshots, err
}

func saveSnapshots(path string, snapshots []Snapshot) error {
	data, err := json.Marshal(snapshots)
	if err != nil {
		return err
	}
	if len(data) > maxSnapshotSize {
		return errResponseSize
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".account-snapshots-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func usableQuota(s Snapshot) bool {
	for _, g := range s.Groups {
		for _, m := range g.Items {
			if m.UsedPercent != nil || m.RemainingPercent != nil || m.UsedAmount != "" || m.RemainingAmount != "" || m.TotalAmount != "" {
				return true
			}
		}
	}
	return false
}

// Wallet amounts can change when the local CLI signs in to a different account.
func withoutCachedWallet(s Snapshot) Snapshot {
	if len(s.AccountCredits) > 0 {
		s.Summary = ""
	}
	kept := make([]Group, 0, len(s.Groups))
	for _, g := range s.Groups {
		items := make([]Metric, 0, len(g.Items))
		for _, m := range g.Items {
			if m.Kind == "balance" {
				// Summary or group subtitle may contain the same amount in display text.
				s.Summary = ""
				g.Subtitle = ""
			} else {
				items = append(items, m)
			}
		}
		g.Items = items
		if len(items) > 0 {
			kept = append(kept, g)
		}
	}
	s.Groups = kept
	s.AccountCredits = nil
	return s
}

func mergeSnapshot(now time.Time, previous Snapshot, current Snapshot) Snapshot {
	if previous.ProviderID == "" {
		return current
	}
	if current.Status != "ok" && !usableQuota(current) {
		previous = withoutCachedWallet(previous)
		if usableQuota(previous) {
			// A failed account request may follow a switch of login. Only the current
			// response can vouch for the wallet; timestamp the windows with their last read.
			previous.Status = "warning"
			previous.Message = current.Message
			previous.AccountCredits = current.AccountCredits
			return previous
		}
		return current
	}
	if current.ResetCredits == nil {
		current.ResetCredits = previous.ResetCredits
	}
	primary := -1
	present := map[string]bool{}
	for i, g := range current.Groups {
		if primary < 0 && g.Title == current.DisplayName {
			primary = i
		}
		for _, m := range g.Items {
			present[m.ID] = true
		}
	}
	if primary < 0 {
		return current
	}
	items := current.Groups[primary].Items
	for _, g := range previous.Groups {
		if g.Title != previous.DisplayName {
			continue
		}
		for _, m := range g.Items {
			if m.Kind != "quota" || m.WindowDurationMinutes == nil || present[m.ID] {
				continue
			}
			if m.ResetAt != "" {
				end, err := time.Parse(time.RFC3339, m.ResetAt)
				if err != nil || !end.After(now) {
					continue
				}
			}
			items = append(items, m)
		}
		break
	}
	if len(items) != len(current.Groups[primary].Items) {
		duration := func(m Metric) int {
			if m.WindowDurationMinutes != nil {
				return *m.WindowDurationMinutes
			}
			return math.MaxInt
		}
		sort.SliceStable(items, func(i, j int) bool { return duration(items[i]) < duration(items[j]) })
		current.Groups[primary].Items = items
	}
	return current
}
