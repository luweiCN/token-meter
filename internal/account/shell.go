package account

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var tmuxStyle = regexp.MustCompile(`#\[[^\]]*\]`)
var reportedPercent = regexp.MustCompile(`[0-9]+(?:\.[0-9]+)?%`)

func collectShellCommand(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	cfg := p.Command
	if cfg == nil || cfg.Executable == "" {
		return Snapshot{}, errors.New("命令配置缺失")
	}
	exe, err := e.LookPath(e.ExpandPath(cfg.Executable))
	if err != nil {
		return Snapshot{}, errors.New("未找到配置的额度命令")
	}
	args := make([]string, len(cfg.Arguments))
	for i, arg := range cfg.Arguments {
		args[i] = e.ExpandPath(arg)
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, exe, args...)
	cmd.WaitDelay = time.Second
	cmd.Env = append(cmd.Environ(), "PATH="+e.SearchPath())
	for name, val := range cfg.Environment {
		cmd.Env = append(cmd.Env, name+"="+val)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return Snapshot{}, err
	}
	if err := cmd.Start(); err != nil {
		if ctx.Err() != nil {
			return Snapshot{}, ctx.Err()
		}
		return Snapshot{}, errors.New("无法启动配置的额度命令")
	}
	stopReading := context.AfterFunc(ctx, func() { out.Close() })
	data, readErr := readLimited(out, 1<<20)
	stopReading()
	interruption := ctx.Err()
	if readErr != nil {
		cancel()
		_ = out.Close()
	}
	err = cmd.Wait()
	if interruption != nil {
		return Snapshot{}, interruption
	}
	if readErr != nil {
		return Snapshot{}, readErr
	}
	if ctx.Err() != nil {
		return Snapshot{}, ctx.Err()
	}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return Snapshot{}, fmt.Errorf("命令退出 %d", exit.ExitCode())
		}
		return Snapshot{}, errors.New("额度命令执行失败")
	}
	plain := strings.TrimSpace(strings.ReplaceAll(tmuxStyle.ReplaceAllString(string(data), ""), "\n", " "))
	if plain == "" {
		return Snapshot{}, errors.New("命令没有输出")
	}
	percent := strings.TrimSuffix(reportedPercent.FindString(plain), "%")
	remaining, err := strconv.ParseFloat(percent, 64)
	if err != nil {
		return Snapshot{}, errors.New("命令输出中没有百分比")
	}
	metric := remainingMetric(p, "额度", remaining)
	metric.Detail = plain
	snapshot := oneGroupSnapshot(p, "ok", plain, []Metric{metric})
	snapshot.Message = plain
	return snapshot, nil
}
