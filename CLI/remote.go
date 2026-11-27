package main

import (
	"context"
	"errors"

	"github.com/luweiCN/token-meter/internal/device"
)

func (s *Store) remoteReport(ctx context.Context, via, host, from, to string) (Report, error) {
	if via != "any" && !device.ValidID(via) {
		return Report{}, errors.New("--via expects a peer ID or any")
	}
	id := via
	if via == "any" {
		id = ""
	}
	peers, err := s.peerRoutes(ctx, id, true)
	if err != nil {
		return Report{}, err
	}
	if len(peers) == 0 {
		return Report{}, errors.New("no paired query endpoint")
	}
	var errs []error
	for _, p := range peers {
		if err := ctx.Err(); err != nil {
			return Report{}, err
		}
		var report Report
		err := device.QueryUsage(ctx, s.key, p, host, from, to, &report)
		if err == nil {
			err = s.checkOutboundGrant(ctx, p.ID, true)
		}
		_ = s.recordPeerAttempt(ctx, p.ID, err)
		if err == nil {
			return report, nil
		}
		errs = append(errs, err)
	}
	return Report{}, errors.Join(errs...)
}
