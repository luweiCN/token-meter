package account

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os/exec"
	"strconv"
	"strings"
)

const maxBillingOutput = 8 << 20

// Both agent CLIs use bidirectional JSONL and can stay alive after replying.
// Closing the read pipe also unblocks a pending read if a hook inherited stdout.
func agentControlStream(ctx context.Context, cmd *exec.Cmd, exchange func(io.WriteCloser, *bufio.Scanner) error) error {
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	defer out.Close()
	if err = cmd.Start(); err != nil {
		return err
	}
	stop := context.AfterFunc(ctx, func() { out.Close(); in.Close() })
	defer stop()
	scanner := bufio.NewScanner(io.LimitReader(out, maxBillingOutput+1))
	scanner.Buffer(make([]byte, 16<<10), maxBillingOutput)
	err = exchange(in, scanner)
	in.Close()
	out.Close()
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if scanner.Err() != nil {
		return errors.New("额度响应过大或读取中断")
	}
	return err
}

func creditNumber(n float64) string {
	return strings.TrimSuffix(strconv.FormatFloat(n, 'f', 1, 64), ".0")
}
