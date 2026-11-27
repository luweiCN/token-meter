package account

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	tokenmeter "github.com/luweiCN/token-meter"
	_ "modernc.org/sqlite"
)

type config struct {
	Providers []Provider `json:"providers"`
}

func decodeConfig(data []byte) ([]Provider, error) {
	var c config
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, err
	}
	if c.Providers == nil {
		return nil, errors.New("missing providers array")
	}
	seen := make(map[string]bool, len(c.Providers))
	for _, p := range c.Providers {
		if p.ID == "" || p.Type == "" || p.DisplayName == "" || seen[p.ID] {
			return nil, errors.New("invalid or duplicate account provider")
		}
		seen[p.ID] = true
	}
	return c.Providers, nil
}

func sqliteFile(path string) string {
	path = filepath.ToSlash(path)
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	u := url.URL{Scheme: "file", Path: path}
	return u.String()
}

type preferences struct {
	providers []Provider
	interval  time.Duration
}

func readPreferences(ctx context.Context, home string) (preferences, error) {
	defaults, err := decodeConfig(tokenmeter.BundledAccountProviders)
	if err != nil {
		return preferences{}, err
	}
	result := preferences{defaults, 5 * time.Minute}
	base := filepath.Join(home, ".token-meter")
	path := os.Getenv("TOKENMETER_CONFIG")
	if path == "" {
		path = filepath.Join(base, "config.json")
	}
	f, err := os.Open(path)
	if err == nil {
		data, readErr := readLimited(f, 2<<20)
		f.Close()
		if readErr != nil {
			return result, readErr
		}
		result.providers, err = decodeConfig(data)
		if err != nil {
			return result, fmt.Errorf("account configuration: %w", err)
		}
		// Existing configs can enable Antigravity from settings without a JSON edit.
		for _, d := range defaults {
			if d.Type != "antigravity" {
				continue
			}
			found := false
			for _, p := range result.providers {
				if p.Type == d.Type || p.ID == d.ID {
					found = true
					break
				}
			}
			if !found {
				result.providers = append(result.providers, d)
			}
			break
		}
	} else if !os.IsNotExist(err) || os.Getenv("TOKENMETER_CONFIG") != "" {
		return result, err
	}

	path = filepath.Join(base, "tokenmeter.sqlite")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return result, nil
	} else if err != nil {
		return result, err
	}
	db, err := sql.Open("sqlite", sqliteFile(path)+"?mode=ro&_pragma=query_only(1)&_pragma=busy_timeout(2500)")
	if err != nil {
		return result, err
	}
	defer db.Close()
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	var overrides, settings bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='provider_config_overrides'), EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings')").Scan(&overrides, &settings); err != nil {
		return result, err
	}
	if overrides {
		rows, err := tx.QueryContext(ctx, "SELECT provider_id, enabled FROM provider_config_overrides WHERE enabled IS NOT NULL")
		if err != nil {
			return result, err
		}
		enabled := map[string]bool{}
		for rows.Next() {
			var id string
			var flag int
			if err = rows.Scan(&id, &flag); err != nil {
				rows.Close()
				return result, err
			}
			enabled[id] = flag == 1
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return result, err
		}
		for i, p := range result.providers {
			if v, ok := enabled[p.ID]; ok {
				result.providers[i].Enabled = v
			}
		}
	}
	if settings {
		var seconds int64
		err := tx.QueryRowContext(ctx, "SELECT CAST(value_json AS INTEGER) FROM settings WHERE key='scan.autoRefreshSeconds'").Scan(&seconds)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return result, err
		}
		if seconds > 300 && seconds <= int64((1<<63-1)/time.Second) {
			result.interval = time.Duration(seconds) * time.Second
		}
	}
	return result, tx.Commit()
}

func Providers(home string) ([]Provider, error) {
	conf, err := readPreferences(context.Background(), home)
	return conf.providers, err
}
