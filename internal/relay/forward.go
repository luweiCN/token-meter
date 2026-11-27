package relay

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// Reserve both clients' transfer budget before forwarding. An IP shared by
// both devices pays once. Reservation order also shares outbound bandwidth
// between simultaneous streams without queuing payloads on the server.
func (s *Server) reserve(a, b string, n int64) (time.Duration, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	first := s.clients[a]
	second := s.clients[b]
	if first == nil || second == nil || !s.traffic.available(now, trafficWindow, n, s.options.WindowBytes) ||
		!first.traffic.available(now, trafficWindow, n, s.options.IPWindowBytes) || !second.traffic.available(now, trafficWindow, n, s.options.IPWindowBytes) {
		return 0, false
	}
	s.traffic.used += n
	first.traffic.used += n
	first.last = now
	if first != second {
		second.traffic.used += n
		second.last = now
	}
	if s.options.EgressBytesPerSecond <= 0 {
		return 0, true
	}
	if s.nextWrite.Before(now) {
		s.nextWrite = now
	}
	delay := s.nextWrite.Sub(now)
	s.nextWrite = s.nextWrite.Add(time.Duration(n) * time.Second / time.Duration(s.options.EgressBytesPerSecond))
	return delay, true
}
func (s *Server) bridge(a, b *websocket.Conn, aip, bip string) {
	ctx, cancel := context.WithTimeout(s.ctx, 10*time.Minute)
	defer cancel()
	var transferred, last atomic.Int64
	last.Store(time.Now().Unix())
	a.SetReadLimit(frameLimit)
	b.SetReadLimit(frameLimit)
	done := make(chan struct{}, 2)
	copyFrames := func(dst, src *websocket.Conn) {
		defer func() { cancel(); done <- struct{}{} }()
		for {
			typ, data, err := src.Read(ctx)
			if err != nil || typ != websocket.MessageBinary || len(data) == 0 {
				return
			}
			// Frame overhead counts toward quotas as well, bounding runs of tiny frames.
			n := int64(len(data) + 32)
			if transferred.Add(n) > maxStreamBytes {
				return
			}
			delay, ok := s.reserve(aip, bip, n)
			if !ok {
				return
			}
			if delay > 0 {
				timer := time.NewTimer(delay)
				select {
				case <-ctx.Done():
					timer.Stop()
					return
				case <-timer.C:
				}
			}
			timeout, stop := context.WithTimeout(ctx, 20*time.Second)
			err = dst.Write(timeout, typ, data)
			stop()
			if err != nil {
				return
			}
			last.Store(time.Now().Unix())
		}
	}
	go copyFrames(a, b)
	go copyFrames(b, a)
	tick := time.NewTicker(20 * time.Second)
	defer tick.Stop()
	for ctx.Err() == nil {
		select {
		case <-ctx.Done():
		case <-tick.C:
			if time.Since(time.Unix(last.Load(), 0)) > 90*time.Second {
				cancel()
			}
		}
	}
	a.CloseNow()
	b.CloseNow()
	<-done
	<-done
}
