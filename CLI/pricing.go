package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	assets "github.com/luweiCN/token-meter"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

type rate struct{ InputPerMTok, OutputPerMTok, CacheReadPerMTok, CacheWrite5mPerMTok *float64 }
type price struct {
	rate
	LongContext []struct {
		ThresholdTokens int64
		Rate            rate
	}
	Tiered *struct {
		EffectiveAfter time.Time
		PeakHoursUTC   []int
		WeekdaysOnly   bool
		Holidays       []struct{ Year, Month, Day int }
		Peak, OffPeak  rate
	}
}
type catalog struct {
	Models        map[string]price
	SchemaVersion int
	fingerprint   string
}

func prices(home string) (catalog, error) {
	data, e := os.ReadFile(filepath.Join(home, ".token-meter", "cache", "litellm-pricing-v2.json"))
	if os.IsNotExist(e) {
		data = assets.BundledPricing
	} else if e != nil {
		return catalog{}, e
	}
	var c catalog
	if e = json.Unmarshal(data, &c); e != nil {
		return c, e
	}
	if c.SchemaVersion != 2 || len(c.Models) == 0 {
		return c, fmt.Errorf("unsupported pricing catalog")
	}
	c.fingerprint = fmt.Sprintf("%x", sha256.Sum256(data))
	return c, nil
}
func (c catalog) estimate(m string, t time.Time, v Counts) (int64, bool) {
	p, ok := c.Models[strings.ToLower(m)]
	if !ok {
		_, suffix, found := strings.Cut(m, "/")
		if found {
			p, ok = c.Models[strings.ToLower(suffix)]
		}
	}
	if !ok {
		return 0, false
	}
	r := p.rate
	if tier := p.Tiered; tier != nil {
		if !t.Before(tier.EffectiveAfter) {
			d := t.In(time.FixedZone("CST", 8*3600))
			peak := slices.Contains(tier.PeakHoursUTC, t.UTC().Hour())
			if tier.WeekdaysOnly {
				peak = peak && d.Weekday() != time.Saturday && d.Weekday() != time.Sunday
				for _, h := range tier.Holidays {
					if h.Year == d.Year() && h.Month == int(d.Month()) && h.Day == d.Day() {
						peak = false
					}
				}
			}
			if peak {
				r = tier.Peak
			} else {
				r = tier.OffPeak
			}
		}
	} else {
		for _, tier := range p.LongContext {
			if v.Input+v.CacheRead+v.CacheWrite > tier.ThresholdTokens {
				r = tier.Rate
			}
		}
	}
	var cost float64
	for _, x := range []struct {
		n int64
		p *float64
	}{{v.Input, r.InputPerMTok}, {v.Output, r.OutputPerMTok}, {v.CacheRead, r.CacheReadPerMTok}, {v.CacheWrite, r.CacheWrite5mPerMTok}} {
		if x.n == 0 {
			continue
		}
		if x.n < 0 || x.p == nil || *x.p < 0 {
			return 0, false
		}
		cost += float64(x.n) * (*x.p)
	}
	if cost >= float64(math.MaxInt64) {
		return 0, false
	}
	return int64(math.Round(cost)), true
}
