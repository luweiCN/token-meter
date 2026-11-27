package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const clawImportDirectory = "session-sqlite-import-archive"

var clawImportSuffix = regexp.MustCompile(`\.jsonl\.imported-[0-9]+(?:\.[1-9][0-9]?)?$`)

func clawImportStem(name string) string {
	pos := clawImportSuffix.FindStringIndex(name)
	if pos == nil {
		return ""
	}
	stem := clawSessionStem(name[:pos[0]])
	key, base, ok := strings.Cut(stem, ".")
	if !ok || key == "" || base == "" {
		return ""
	}
	return stem
}

// The migration joins a sanitized session key and filename with a dot. Both
// can themselves contain dots, so completed moves preserve the original name.
type clawImportOrigins map[[2]string]string

func (m *clawImportOrigins) session(path string) string {
	dir := filepath.Dir(path)
	if *m == nil {
		*m = clawImportOrigins{}
		runs := filepath.Join(dir, "..", "..", "..", "session-sqlite-migration-runs")
		files, _ := os.ReadDir(runs)
		for _, file := range files {
			if !file.Type().IsRegular() || filepath.Ext(file.Name()) != ".json" {
				continue
			}
			var manifest struct {
				Targets []struct {
					CompletedMoves []struct{ ArchivePath, SourcePath, Kind string }
				}
			}
			raw, err := os.ReadFile(filepath.Join(runs, file.Name()))
			if err != nil || json.Unmarshal(raw, &manifest) != nil {
				continue
			}
			for _, target := range manifest.Targets {
				for _, move := range target.CompletedMoves {
					if move.Kind != "transcript" && move.Kind != "unreferenced-jsonl" {
						continue
					}
					archiveDir, srcDir := filepath.Dir(move.ArchivePath), filepath.Dir(move.SourcePath)
					agent := filepath.Base(filepath.Dir(archiveDir))
					if filepath.Base(archiveDir) != clawImportDirectory || filepath.Base(srcDir) != "sessions" || filepath.Base(filepath.Dir(srcDir)) != agent {
						continue
					}
					base := filepath.Base(move.SourcePath)
					if id := clawSessionID(base); strings.HasSuffix(base, ".jsonl") && id != "" {
						(*m)[[2]string{agent, filepath.Base(move.ArchivePath)}] = id
					}
				}
			}
		}
	}
	name := filepath.Base(path)
	if id, ok := (*m)[[2]string{filepath.Base(filepath.Dir(dir)), name}]; ok {
		return id
	}
	stem := clawImportStem(name)
	if id, ok := strings.CutPrefix(stem, "archive-tier."); ok {
		return id
	}
	_, id, ok := strings.Cut(stem, ".")
	if ok && !strings.Contains(id, ".") {
		return id
	}
	// A session header or a provider response ID can still identify these rows.
	return ""
}

func (c catalog) clawImportedFile(path string, imports *clawImportOrigins, emit emitSample) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return c.clawLines(f, imports.session(path), emit)
}
