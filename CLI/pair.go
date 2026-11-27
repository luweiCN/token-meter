package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/luweiCN/token-meter/internal/device"
)

func (s *Store) pairPreflight(id, role string) error {
	var prior string
	err := s.db.QueryRow("SELECT role FROM peers WHERE id=?", id).Scan(&prior)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if prior != role {
		return errors.New("这台设备已按另一种权限配对，请先解除原配对")
	}
	return nil
}

func pairRoleName(role string) string {
	if role == "viewer" {
		return "只读查看"
	}
	return "双向同步（彼此可查看已同步的用量）"
}
func printPairEvent(w io.Writer, p device.PairEvent) error {
	var msg string
	switch p.State {
	case "invitation":
		msg = fmt.Sprintf("配对码  %s\n邀请链接  %s\n另一台设备可点「添加设备」或运行 token-meter pair --join 输入配对码。邀请 10 分钟有效。", p.Code, p.URL)
	case "connecting":
		msg = "正在连接邀请设备…"
	case "confirm":
		msg = fmt.Sprintf("%s · %s\n两台设备的校验码应当相同  %s", p.Name, pairRoleName(p.Role), p.Verification)
		if p.CanApprove {
			msg += "\n确认配对？[y/N]"
		} else {
			msg += "\n等待邀请方确认…"
		}
	case "waiting":
		msg = "已确认，正在等待另一台设备…"
	case "paired":
		msg = fmt.Sprintf("已与 %s 配对 · %s", p.Name, pairRoleName(p.Role))
	default:
		msg = p.Message
	}
	_, err := fmt.Fprintln(w, msg)
	return err
}

func (s *Store) pair(ctx context.Context, args []string) error {
	return s.pairIO(ctx, args, os.Stdin, os.Stdout)
}
func (s *Store) pairIO(ctx context.Context, args []string, in io.Reader, out io.Writer) error {
	flags := flag.NewFlagSet("pair", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	jsonMode := flags.Bool("json", false, "use line-delimited JSON")
	joinStdin := flags.Bool("join-stdin", false, "read one JSON invitation from standard input")
	joinPrompt := flags.Bool("join", false, "enter a pairing code or link at the prompt")
	role := flags.String("role", "peer", "peer or viewer")
	base := flags.String("relay", device.DefaultRelayURL, "rendezvous service URL")
	if e := flags.Parse(args); e != nil {
		return e
	}
	enc := json.NewEncoder(out)
	emit := func(p device.PairEvent) error {
		if *jsonMode {
			return enc.Encode(p)
		}
		return printPairEvent(out, p)
	}
	fail := func(err error) error {
		state, msg := device.PairErrorState(err)
		if *jsonMode {
			_ = emit(device.PairEvent{State: state, Message: msg})
		}
		return errors.New(msg)
	}
	if *role != "peer" && *role != "viewer" {
		return fail(errors.New("权限必须是 peer（双向同步）或 viewer（只读查看）"))
	}
	if flags.NArg() > 1 || ((*joinStdin || *joinPrompt) && flags.NArg() != 0) || (*joinStdin && *joinPrompt) || (*joinPrompt && *jsonMode) {
		return fail(errors.New("用法：token-meter pair [--join | 配对码]"))
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// A GUI owns the lifetime of its child via stdin. Its disappearance cancels
	// even a read-only join or an outstanding invitation waiting in Accept.
	if reader, ok := in.(io.ReadCloser); ok && in != os.Stdin {
		defer reader.Close()
	}
	lines := make(chan string, 2)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(in)
		scanner.Buffer(make([]byte, 512), 4096)
		for scanner.Scan() {
			select {
			case lines <- scanner.Text():
			case <-ctx.Done():
				return
			}
		}
		if *jsonMode {
			cancel()
		}
	}()
	readLine := func(wait context.Context) (string, error) {
		select {
		case <-wait.Done():
			return "", wait.Err()
		case line, open := <-lines:
			if !open {
				return "", device.ErrPairCancelled
			}
			return line, nil
		}
	}
	input := flags.Arg(0)
	if *joinPrompt {
		if _, err := fmt.Fprintln(out, "输入另一台设备的配对码，或粘贴邀请链接："); err != nil {
			return err
		}
		var err error
		input, err = readLine(ctx)
		if err != nil {
			return fail(err)
		}
		if strings.TrimSpace(input) == "" {
			return fail(errors.New("请输入配对码或邀请链接"))
		}
	}
	if *joinStdin {
		line, e := readLine(ctx)
		if e != nil {
			return fail(e)
		}
		var item struct {
			Invitation string `json:"invitation"`
		}
		if json.Unmarshal([]byte(line), &item) != nil || item.Invitation == "" {
			return fail(errors.New("请输入配对码或邀请链接"))
		}
		input = item.Invitation
	}
	ui := device.PairInteraction{Emit: emit, Approve: func(ctx context.Context) (bool, error) {
		line, err := readLine(ctx)
		if err != nil {
			return false, err
		}
		if *jsonMode {
			var a struct {
				Approve *bool `json:"approve"`
			}
			if json.Unmarshal([]byte(line), &a) != nil || a.Approve == nil {
				return false, errors.New("需要明确确认或拒绝配对")
			}
			return *a.Approve, nil
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "y", "yes", "是", "确认":
			return true, nil
		}
		return false, nil
	}}
	hostname, _ := os.Hostname()
	pairing := device.Pairing{
		Key: s.key, Name: s.setting("name", hostname), Address: s.pairDirectAddress(),
		Preflight: s.pairPreflight,
		Prepare: func(peer device.PairIdentity, role, relayURL string) (device.PreparedGrant, error) {
			return s.preparePaired(peer.ID, peer.Address, role, relayURL, peer.Name)
		},
	}
	if err := pairing.Run(ctx, *base, input, *role, ui); err != nil {
		if ctx.Err() != nil {
			return fail(ctx.Err())
		}
		return fail(err)
	}
	return nil
}
