package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/luweiCN/token-meter/internal/relay"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:47739", "HTTP listen address behind a TLS reverse proxy")
	proxy := flag.Bool("trust-loopback-proxy", false, "use the single client IP set by a trusted loopback reverse proxy")
	window := flag.Int64("window-mib", 4096, "total MiB transferable per ten-minute window")
	ipWindow := flag.Int64("ip-window-mib", 512, "per-client MiB transferable per ten-minute window")
	egress := flag.Int64("egress-kib-per-sec", 0, "outgoing KiB per second across streams (0 uses only window limits)")
	flag.Parse()
	if *window <= 0 || *window > 1<<30 || *ipWindow <= 0 || *ipWindow > 1<<30 || *egress < 0 || *egress > 1<<30 {
		fmt.Fprintln(os.Stderr, "invalid bandwidth limits")
		os.Exit(2)
	}
	handler := relay.NewServerWithOptions(relay.ServerOptions{TrustLoopbackProxy: *proxy, WindowBytes: *window << 20, IPWindowBytes: *ipWindow << 20, EgressBytesPerSecond: *egress << 10})
	defer handler.Close()
	srv := &http.Server{Addr: *listen, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8 << 10}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		handler.Close()
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(c)
	}()
	log.Printf("TokenMeter relay listening on %s", *listen)
	if e := srv.ListenAndServe(); e != nil && !errors.Is(e, http.ErrServerClosed) {
		log.Print(e)
		os.Exit(1)
	}
}
