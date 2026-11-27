package main

import (
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type fileCursor struct {
	offset, size              int64
	session, identity, anchor string
}

func anchor(f *os.File, offset int64) (string, error) {
	h := sha256.New()
	for _, r := range [][2]int64{{0, min(offset, 256)}, {max(0, offset-256), min(offset, 256)}} {
		if _, e := io.CopyN(h, io.NewSectionReader(f, r[0], r[1]), r[1]); e != nil {
			return "", e
		}
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}

// Compare the selected record before and after a changed line. Rotation and
// branches can publish the same request in several files with different IDs.
type bucketMap map[[3]string]Counts

func (m bucketMap) apply(st *sql.Stmt, id string, sign int64) error {
	var b Bucket
	e := st.QueryRow(id).Scan(&b.Day, &b.Agent, &b.Model, &b.Input, &b.Output, &b.CacheRead, &b.CacheWrite, &b.CostMicros, &b.UnknownCost, &b.Events)
	if errors.Is(e, sql.ErrNoRows) {
		return nil
	}
	if e != nil {
		return e
	}
	m.addBucket(b, sign)
	return nil
}

func (m bucketMap) addBucket(b Bucket, sign int64) {
	k := [3]string{b.Day, b.Agent, b.Model}
	v := m[k]
	v.Input += sign * b.Input
	v.Output += sign * b.Output
	v.CacheRead += sign * b.CacheRead
	v.CacheWrite += sign * b.CacheWrite
	v.CostMicros += sign * b.CostMicros
	v.UnknownCost += sign * b.UnknownCost
	v.Events += sign * b.Events
	if v == (Counts{}) {
		delete(m, k)
	} else {
		m[k] = v
	}
}
func (m bucketMap) buckets() []Bucket {
	buckets := make([]Bucket, 0, len(m))
	for k, v := range m {
		buckets = append(buckets, Bucket{k[0], k[1], k[2], v})
	}
	return buckets
}
func (s *Store) indexLines(tx *sql.Tx, src source, cat catalog, old, revision string, emit emitSample, repair *checkpointIDRepair) error {
	f, e := os.Open(src.path)
	if e != nil {
		return e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil {
		return e
	}
	identity, e := fileIdentity(f)
	if e != nil {
		return e
	}
	cur := fileCursor{}
	err := tx.QueryRow("SELECT offset,size,session,identity,anchor FROM source_cursors WHERE file=?", src.path).Scan(&cur.offset, &cur.size, &cur.session, &cur.identity, &cur.anchor)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	appendOnly := false
	if repair == nil && err == nil && cur.size < st.Size() && cur.offset <= cur.size && cur.identity == identity && strings.HasPrefix(old, revision+":") {
		a, e := anchor(f, cur.offset)
		if e != nil {
			return e
		}
		appendOnly = a == cur.anchor
	}
	if !appendOnly {
		cur.offset = 0
		cur.session = clawSessionID(filepath.Base(src.path))
	}
	n, e := cat.clawStream(io.NewSectionReader(f, cur.offset, st.Size()-cur.offset), &cur.session, emit, true, repair)
	if e != nil {
		return e
	}
	cur.offset += n
	a, e := anchor(f, cur.offset)
	if e != nil {
		return e
	}
	if _, e = tx.Exec("INSERT OR REPLACE INTO source_cursors VALUES(?,?,?,?,?,?)", src.path, cur.offset, st.Size(), cur.session, identity, a); e != nil {
		return e
	}
	return nil
}
