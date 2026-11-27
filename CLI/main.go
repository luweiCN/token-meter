package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/luweiCN/token-meter/internal/account"
	"github.com/luweiCN/token-meter/internal/device"
)

const help = `TokenMeter — device usage and account quotas

token-meter [--state DIR] [--home DIR] COMMAND
  scan                            Index local usage now
  usage [--via PEER|any] [--host ID|local] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--json]
  pair [CODE|INVITATION]          Add a device with a one-time pairing code
  identity                        Print this device's public pairing ID
  config NAME VALUE               name, listen, openclaw, hermes, auto-update
  account PROVIDER ALIAS          Group readings from the same billing account
  peer add ID HOST:PORT           Trust this peer; repeat on the other device
  peer viewer ID                  Authorize a read-only client
  peer list | peer remove ID
  sync                            Fetch newer snapshots from paired devices
  quota-refresh [PROVIDER]        Refresh enabled accounts or one provider
  daemon                          Run foreground collector and replication server
  service install|status|uninstall
  service install-boot USER       macOS system startup as the specified user (sudo)
  update                          Check and install an official verified release
  version`

func printJSON(v any) error { return json.NewEncoder(os.Stdout).Encode(v) }
func (s *Store) usage(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("usage", flag.ContinueOnError)
	via := fs.String("via", "", "query a paired device directly")
	host := fs.String("host", "", "device ID or local")
	from := fs.String("from", "", "first day")
	to := fs.String("to", "", "last day")
	j := fs.Bool("json", false, "JSON output")
	if e := fs.Parse(args); e != nil {
		return e
	}
	if !device.ValidRange(*from, *to) || fs.NArg() != 0 {
		return errors.New("invalid usage arguments or date range")
	}
	var r Report
	var e error
	if *via == "" {
		r, e = s.report(*host, *from, *to)
	} else {
		r, e = s.remoteReport(ctx, *via, *host, *from, *to)
	}
	if e != nil {
		return e
	}
	if *j {
		return printJSON(r)
	}
	fmt.Printf("%d tokens · $%.2f", r.Tokens, float64(r.CostMicros)/1e6)
	if r.UnknownCost > 0 {
		fmt.Printf(" (+ %d unpriced events)", r.UnknownCost)
	}
	if r.UnknownTokens > 0 {
		fmt.Printf(" (+ %d events without token counts)", r.UnknownTokens)
	}
	fmt.Println()
	for _, d := range r.Devices {
		fmt.Printf("  %s (%s)  %d tokens  as of %s\n", d.Name, d.OS, d.Tokens, time.Unix(d.Observed, 0).Local().Format(time.RFC3339))
		if d.PartialSources > 0 {
			fmt.Printf("    %d sources could not be refreshed\n", d.PartialSources)
		}
	}
	for _, b := range r.Agents {
		fmt.Printf("  %s / %s  %d tokens\n", b.Agent, b.Model, b.tokens())
	}
	for _, q := range r.Quotas {
		fmt.Printf("  %s · %s", q.Provider, q.Observed)
		for _, w := range q.Windows {
			switch {
			case w.Remaining != nil:
				fmt.Printf("  %s %.0f%%", w.Label, *w.Remaining)
			case w.RemainingAmount != "":
				fmt.Printf("  %s %s %s remaining", w.Label, w.RemainingAmount, w.Unit)
			case w.UsedAmount != "":
				fmt.Printf("  %s %s %s used", w.Label, w.UsedAmount, w.Unit)
			case w.TotalAmount != "":
				fmt.Printf("  %s %s %s total", w.Label, w.TotalAmount, w.Unit)
			}
		}
		if q.Balance != "" {
			fmt.Printf("  %s %s", q.Balance, q.balanceLabel())
		}
		fmt.Println()
	}
	return nil
}
func (s *Store) command(ctx context.Context, args []string) error {
	switch args[0] {
	case "version":
		fmt.Println(version)
		return nil
	case "identity":
		fmt.Println(s.id)
		return nil
	case "scan":
		return s.scan()
	case "usage":
		return s.usage(ctx, args[1:])
	case "sync":
		return s.sync(ctx)
	case "pair":
		return s.pair(ctx, args[1:])
	case "quota-refresh":
		if len(args) > 2 {
			break
		}
		only := ""
		if len(args) == 2 {
			only = args[1]
		}
		return s.refreshAccounts(ctx, only, true)
	case "daemon":
		return s.serve(ctx)
	case "supervise":
		return s.supervise(ctx)
	case "update":
		applied, e := s.update(ctx)
		if e == nil {
			if applied {
				fmt.Println("Verified update installed")
			} else {
				fmt.Println("Up to date")
			}
		}
		return e
	case "service":
		if len(args) == 2 {
			return s.service(args[1], "")
		}

	case "account":
		if len(args) == 3 && args[1] != "" && args[2] != "" {
			return s.set("account."+args[1], args[2])
		}
	case "config":
		if len(args) != 3 {
			break
		}
		k, v := args[1], args[2]
		switch k {
		case "listen":
			if _, _, e := net.SplitHostPort(v); e != nil {
				return e
			}
		case "openclaw", "hermes":
			if !filepath.IsAbs(v) {
				return errors.New("source directory must be absolute")
			}
		case "auto-update":
			if v != "true" && v != "false" {
				return errors.New("choose true or false")
			}
		case "name":
			if strings.TrimSpace(v) == "" || len(v) > 255 {
				return errors.New("invalid name")
			}
		default:
			return errors.New("unknown configuration key")
		}
		return s.set(k, v)
	case "peer":
		if len(args) == 4 && args[1] == "add" {
			return s.addPeer(args[2], args[3], "peer")
		}
		if len(args) == 3 && args[1] == "viewer" {
			return s.addPeer(args[2], "", "viewer")
		}
		if len(args) == 3 && args[1] == "remove" {
			return s.removePeer(args[2])
		}
		if len(args) == 3 && args[1] == "list" && args[2] == "--json" {
			devices, err := s.pairedDevices()
			if err != nil {
				return err
			}
			return printJSON(devices)
		}
		if len(args) == 2 && args[1] == "list" {
			rows, e := s.db.Query("SELECT id,address,role,last_ok,last_error FROM peers ORDER BY id")
			if e != nil {
				return e
			}
			defer rows.Close()
			for rows.Next() {
				var id, a, role, msg string
				var at int64
				if e = rows.Scan(&id, &a, &role, &at, &msg); e != nil {
					return e
				}
				fmt.Printf("%s %s %s last_sync=%d %s\n", id, role, a, at, msg)
			}
			return rows.Err()
		}
	}
	return errors.New("invalid command; see token-meter --help")
}
func entry() error {
	account.ClientVersion = version
	if len(os.Args) == 2 && os.Args[1] == "_check" {
		return selfCheck()
	}
	home, e := os.UserHomeDir()
	if e != nil {
		if owner, err := user.Current(); err == nil {
			home = owner.HomeDir
		}
	}
	f := flag.NewFlagSet("token-meter", flag.ContinueOnError)
	dir := f.String("state", os.Getenv("TOKEN_METER_STATE_DIR"), "device data directory")
	homeDir := f.String("home", home, "agent account home")
	f.Usage = func() { fmt.Println(help) }
	if e = f.Parse(os.Args[1:]); errors.Is(e, flag.ErrHelp) {
		return nil
	} else if e != nil {
		return e
	}
	args := f.Args()
	if len(args) == 0 || args[0] == "help" {
		fmt.Println(help)
		return nil
	}
	if *homeDir == "" {
		return errors.New("supply --home for the agent account")
	}
	if *dir == "" {
		*dir = filepath.Join(*homeDir, ".token-meter", "node")
	}
	abs, e := filepath.Abs(*dir)
	if e != nil {
		return e
	}
	base, e := filepath.Abs(*homeDir)
	if e != nil {
		return e
	}
	if len(args) >= 2 && args[0] == "service" && strings.HasSuffix(args[1], "-boot") {
		if runtime.GOOS != "darwin" || len(args) != 3 || args[2] == "" {
			return errors.New("supply the target macOS user for a boot service")
		}
		// launchd administration must not open the user's SQLite WAL as root.
		return (&Store{dir: abs, home: base}).service(args[1], args[2])
	}
	// These read-only helpers run from the agent's status line and local indexer.
	// Dispatch to the active build without opening SQLite on every terminal repaint.
	if args[0] == "antigravity-capture" || args[0] == "qoder-models" {
		light := &Store{dir: abs, home: base}
		if a, err := light.active(); err == nil && newer(a.Version, version) {
			return light.forward(a.Version)
		}
		if args[0] == "antigravity-capture" {
			return account.AntigravityCapture(base, args[1:], os.Stdin, os.Stdout)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		models, err := account.QoderModels(ctx, account.Environment{Home: base})
		if err != nil {
			return err
		}
		return printJSON(models)
	}
	if len(args) == 2 && args[0] == "service" && args[1] == "ensure" {
		if err := os.MkdirAll(abs, 0700); err != nil {
			return err
		}
		return (&Store{dir: abs, home: base}).service("ensure", "")
	}
	s, e := openStore(abs, base)
	if e != nil {
		return e
	}
	defer s.db.Close()
	if args[0] != "supervise" {
		a, e := s.active()
		if e != nil {
			return e
		}
		if newer(a.Version, version) {
			return s.forward(a.Version)
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return s.command(ctx, args)
}
func main() {
	if e := entry(); e != nil {
		fmt.Fprintln(os.Stderr, "token-meter:", e)
		os.Exit(1)
	}
}
