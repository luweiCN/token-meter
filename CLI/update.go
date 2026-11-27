package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	assets "github.com/luweiCN/token-meter"
	"github.com/luweiCN/token-meter/internal/device"
)

var version = "1.15.0-dev"

const releaseAPI = "https://api.github.com/repos/luweiCN/token-meter/releases/latest"

var versionPattern = regexp.MustCompile(`^([0-9]+)\.([0-9]+)\.([0-9]+)(-dev)?$`)

func newer(a, b string) bool {
	x, y := versionPattern.FindStringSubmatch(a), versionPattern.FindStringSubmatch(b)
	if x == nil || y == nil {
		return false
	}
	for i := 1; i <= 3; i++ {
		u, ue := strconv.ParseUint(x[i], 10, 32)
		v, ve := strconv.ParseUint(y[i], 10, 32)
		if ue != nil || ve != nil {
			return false
		}
		if u != v {
			return u > v
		}
	}
	return x[4] == "" && y[4] != ""
}
func binaryName() string {
	if runtime.GOOS == "windows" {
		return "token-meter.exe"
	}
	return "token-meter"
}
func assetName() string {
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	return "token-meter-" + runtime.GOOS + "-" + runtime.GOARCH + suffix
}

type release struct {
	Tag               string `json:"tag_name"`
	Draft, Prerelease bool
	Assets            []struct {
		Name, Digest string
		URL          string `json:"browser_download_url"`
	}
}
type activeBuild struct {
	Version  string `json:"version"`
	Previous string `json:"previous,omitempty"`
}

func (s *Store) buildPath(v string) string { return filepath.Join(s.dir, "versions", v, binaryName()) }
func (s *Store) active() (activeBuild, error) {
	var a activeBuild
	e := loadOptional(filepath.Join(s.dir, "active.json"), &a)
	if a.Version != "" && !versionPattern.MatchString(a.Version) {
		return a, errors.New("invalid installed release")
	}
	return a, e
}
func (s *Store) activate(a activeBuild) error {
	return atomicJSON(filepath.Join(s.dir, "active.json"), a)
}

// An app upgrade and the daemon's release download may complete together.
// Serialize only their on-disk installation, independently of ledger writes.
func (s *Store) withRuntimeLock(install func() error) error {
	db, err := sql.Open("sqlite", sqlitePath(filepath.Join(s.dir, "runtime-lock.sqlite"))+"?_txlock=immediate&_pragma=busy_timeout(10000)")
	if err != nil {
		return err
	}
	defer db.Close()
	lock, err := db.Begin()
	if err != nil {
		return err
	}
	defer lock.Rollback()
	return install()
}

func copyBinary(from, to string) error {
	if e := os.MkdirAll(filepath.Dir(to), 0700); e != nil {
		return e
	}
	in, e := os.Open(from)
	if e != nil {
		return e
	}
	defer in.Close()
	f, e := os.CreateTemp(filepath.Dir(to), ".install-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if _, e = io.Copy(f, in); e == nil {
		e = f.Chmod(0700)
	}
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	return os.Rename(f.Name(), to)
}
func (s *Store) update(ctx context.Context) (bool, error) {
	client := &http.Client{Timeout: 2 * time.Minute}
	var rel release
	if e := device.FetchJSON(ctx, client, releaseAPI, 1<<20, &rel); e != nil {
		return false, e
	}
	return s.applyRelease(ctx, client, rel)
}
func (s *Store) applyRelease(ctx context.Context, c *http.Client, rel release) (bool, error) {
	v := strings.TrimPrefix(rel.Tag, "v")
	if !strings.HasPrefix(rel.Tag, "v") || rel.Draft || rel.Prerelease || !newer(v, version) || strings.Contains(v, "-") {
		return false, nil
	}
	a, e := s.active()
	if e != nil {
		return false, e
	}
	if a.Version != "" && !newer(v, a.Version) {
		return false, nil
	}
	name := assetName()
	for _, asset := range rel.Assets {
		if asset.Name != name {
			continue
		}
		expectedURL := "https://github.com/luweiCN/token-meter/releases/download/" + rel.Tag + "/" + name
		sha, ok := strings.CutPrefix(asset.Digest, "sha256:")
		if !ok || len(sha) != 64 || asset.URL != expectedURL {
			return false, errors.New("missing release digest or unexpected download origin")
		}
		dir := filepath.Join(s.dir, "versions", v)
		if e = os.MkdirAll(dir, 0700); e != nil {
			return false, e
		}
		req, e := http.NewRequestWithContext(ctx, "GET", asset.URL, nil)
		if e != nil {
			return false, e
		}
		res, e := c.Do(req)
		if e != nil {
			return false, e
		}
		defer res.Body.Close()
		if res.StatusCode != 200 {
			return false, fmt.Errorf("download HTTP %d", res.StatusCode)
		}
		f, e := os.CreateTemp(dir, ".download-*"+filepath.Ext(binaryName()))
		if e != nil {
			return false, e
		}
		defer os.Remove(f.Name())
		h := sha256.New()
		n, e := io.Copy(io.MultiWriter(f, h), io.LimitReader(res.Body, (128<<20)+1))
		if e == nil {
			e = f.Chmod(0700)
		}
		if e == nil {
			e = f.Sync()
		}
		ce := f.Close()
		if e != nil {
			return false, e
		}
		if ce != nil {
			return false, ce
		}
		if n > 128<<20 || hex.EncodeToString(h.Sum(nil)) != sha {
			return false, errors.New("release SHA-256 mismatch")
		}
		probeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		probe, e := exec.CommandContext(probeCtx, f.Name(), "_check").Output()
		if e != nil || strings.TrimSpace(string(probe)) != v {
			return false, errors.New("candidate failed CLI and SQLite self-test")
		}
		updated := false
		e = s.withRuntimeLock(func() error {
			current, err := s.active()
			if err != nil {
				return err
			}
			if current.Version != "" && !newer(v, current.Version) {
				return nil
			}
			if err = os.Rename(f.Name(), s.buildPath(v)); err != nil {
				return err
			}
			previous := current.Version
			if previous == "" {
				previous = version
			}
			if _, err := os.Stat(s.buildPath(previous)); os.IsNotExist(err) && previous == version {
				exe, err := os.Executable()
				if err != nil {
					return err
				}
				if err = copyBinary(exe, s.buildPath(previous)); err != nil {
					return err
				}
			} else if err != nil {
				return err
			}
			if err = s.activate(activeBuild{v, previous}); err != nil {
				return err
			}
			updated = true
			return nil
		})
		return updated, e
	}
	return false, fmt.Errorf("release %s has no %s", rel.Tag, name)
}
func (s *Store) supervise(ctx context.Context) error {
	for ctx.Err() == nil {
		a, e := s.active()
		if e != nil {
			return e
		}
		if !versionPattern.MatchString(a.Version) {
			return errors.New("service has no installed runtime")
		}
		started := time.Now()
		cmd := exec.CommandContext(ctx, s.buildPath(a.Version), "--state", s.dir, "--home", s.home, "daemon")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		e = cmd.Run()
		if ctx.Err() != nil {
			return nil
		}
		latest, err := s.active()
		if err != nil {
			return err
		}
		if latest.Version != a.Version {
			continue
		}
		if e != nil && time.Since(started) < 20*time.Second && versionPattern.MatchString(a.Previous) {
			if err = s.activate(activeBuild{Version: a.Previous}); err != nil {
				return err
			}
			continue
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(3 * time.Second):
		}
	}
	return nil
}
func selfCheck() error {
	db, e := sql.Open("sqlite", ":memory:")
	if e != nil {
		return e
	}
	defer db.Close()
	var n int
	if e = db.QueryRow("SELECT 1").Scan(&n); e != nil {
		return e
	}
	if _, e = pricesFromBundle(); e != nil {
		return e
	}
	fmt.Println(version)
	return nil
}
func pricesFromBundle() (int, error) {
	var hdr struct{ SchemaVersion int }
	e := json.Unmarshal(assets.BundledPricing, &hdr)
	if e == nil && hdr.SchemaVersion != 2 {
		return 0, errors.New("unsupported bundled prices")
	}
	return hdr.SchemaVersion, e
}
