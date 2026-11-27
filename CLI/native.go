package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

type nativeStatus struct {
	At       int64 `json:"at"`
	Scanned  int   `json:"scanned"`
	Failures int   `json:"failures"`
	Interval int   `json:"interval"`
}

func (s *Store) nativeLoop(ctx context.Context) {
	if runtime.GOOS != "darwin" {
		return
	}
	home, e := os.UserHomeDir()
	if e != nil || home != s.home {
		return
	}
	helper := s.setting("native-helper", "/Applications/TokenMeter.app/Contents/MacOS/TokenMeterIndex")
	for ctx.Err() == nil {
		interval := time.Minute
		if _, e = os.Stat(helper); e == nil {
			if _, e = os.Stat(filepath.Join(s.dir, "index-paused")); errors.Is(e, os.ErrNotExist) {
				var result nativeStatus
				runCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)
				raw, err := exec.CommandContext(runCtx, helper).Output()
				cancel()
				if err == nil {
					err = json.Unmarshal(raw, &result)
				}
				if err == nil {
					result.At = time.Now().Unix()
					interval = time.Duration(max(30, result.Interval)) * time.Second
					err = atomicJSON(filepath.Join(s.dir, "native-index.json"), result)
				}
				var busy *exec.ExitError
				if err != nil && ctx.Err() == nil && !(errors.As(err, &busy) && busy.ExitCode() == 75) {
					log.Println(fmt.Errorf("native index: %w", err))
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}
