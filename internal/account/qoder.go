package account

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"time"
)

const qoderInit = `{"type":"control_request","request_id":"tokenmeter-initialize","request":{"subtype":"initialize","hooks":{},"sdkMcpServers":[]}}`
const qoderUsageRequest = `{"type":"control_request","request_id":"tokenmeter-usage","request":{"subtype":"get_usage_info"}}`

// Installers keep several versioned binaries beside a version.txt selection.
var qoderVersion = regexp.MustCompile(`^[0-9][0-9A-Za-z.+_-]*$`)

func qoderNaturalVersion(a, b string) int {
	for len(a) > 0 && len(b) > 0 {
		x, y := strings.IndexFunc(a, func(r rune) bool { return r < '0' || r > '9' }), strings.IndexFunc(b, func(r rune) bool { return r < '0' || r > '9' })
		if x < 0 {
			x = len(a)
		}
		if y < 0 {
			y = len(b)
		}
		if x > 0 && y > 0 {
			aa, bb := strings.TrimLeft(a[:x], "0"), strings.TrimLeft(b[:y], "0")
			if len(aa) != len(bb) {
				return len(aa) - len(bb)
			}
			if d := strings.Compare(aa, bb); d != 0 {
				return d
			}
			a, b = a[x:], b[y:]
		} else {
			if a[0] != b[0] {
				return int(a[0]) - int(b[0])
			}
			a, b = a[1:], b[1:]
		}
	}
	return len(a) - len(b)
}

func qoderExecutable(e Environment) (string, error) {
	if configured := strings.TrimSpace(os.Getenv("QODERCLI_PATH")); configured != "" {
		if path, err := e.LookPath(e.ExpandPath(configured)); err == nil {
			return path, nil
		}
		return "", errors.New("找不到 QODERCLI_PATH 指定的 Qoder CLI")
	}
	for _, install := range []struct{ root, name string }{{".qoder-cn", "qoderclicn"}, {".qoder", "qodercli"}} {
		dir := filepath.Join(e.Home, install.root, "bin", install.name)
		prefix := install.name + "-"
		if raw, err := os.ReadFile(filepath.Join(dir, "version.txt")); err == nil {
			if active := strings.TrimSpace(string(raw)); qoderVersion.MatchString(active) {
				if exe, err := e.LookPath(filepath.Join(dir, prefix+active)); err == nil {
					return exe, nil
				}
			}
		}
		entries, _ := os.ReadDir(dir)
		var versions []string
		for _, entry := range entries {
			name, found := strings.CutPrefix(entry.Name(), prefix)
			name = strings.TrimSuffix(name, ".exe")
			if found && !entry.IsDir() && qoderVersion.MatchString(name) {
				versions = append(versions, name)
			}
		}
		slices.SortFunc(versions, func(a, b string) int { return qoderNaturalVersion(b, a) })
		for _, v := range versions {
			if exe, err := e.LookPath(filepath.Join(dir, prefix+v)); err == nil {
				return exe, nil
			}
		}
	}
	for _, name := range []string{"qoderclicn", "qodercli", "qoder"} {
		if exe, err := e.LookPath(name); err == nil {
			return exe, nil
		}
	}
	return "", errors.New("未检测到 Qoder CLI")
}

type QoderModel struct {
	Value       string `json:"value"`
	ModelID     string `json:"modelId,omitempty"`
	DisplayName string `json:"displayName"`
	Source      string `json:"source,omitempty"`
	IsEnabled   *bool  `json:"isEnabled,omitempty"`
}

type qoderQuota struct {
	Total      json.Number
	Used       json.Number
	Remaining  json.Number
	Percentage *float64
	Unit       string
	Cap        json.Number
	Available  *bool
}
type qoderUsage struct {
	IsQuotaExceeded    bool
	UserQuota          *qoderQuota
	AddOnQuota         *qoderQuota
	OrgResourcePackage *qoderQuota
}

type qoderReply struct {
	Models []QoderModel
	Usage  *qoderUsage
}

func qoderControl(ctx context.Context, e Environment, usage bool) (qoderReply, error) {
	exe, err := qoderExecutable(e)
	if err != nil {
		return qoderReply{}, err
	}
	run, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	args := []string{"--print", "--input-format", "stream-json", "--output-format", "stream-json", "--no-session-persistence", "--tools", ""}
	if runtime.GOOS == "windows" && (strings.EqualFold(filepath.Ext(exe), ".cmd") || strings.EqualFold(filepath.Ext(exe), ".bat")) {
		// npm shims normally invoke cmd.exe. Execute the package's declared
		// JavaScript entry point directly so cmd cannot rewrite the SDK arguments.
		script := qoderNPMEntry(exe)
		node, err := e.LookPath("node")
		if script == "" || err != nil {
			return qoderReply{}, errors.New("请安装 Qoder 原生 CLI，或将 QODERCLI_PATH 指向其可执行文件")
		}
		exe, args = node, append([]string{script}, args...)
	}
	cmd := exec.CommandContext(run, exe, args...)
	cmd.Env = append(cmd.Environ(), "PATH="+e.SearchPath())
	return qoderExchange(run, cmd, usage)
}

func qoderNPMEntry(shim string) string {
	name := strings.ToLower(strings.TrimSuffix(filepath.Base(shim), filepath.Ext(shim)))
	for _, pkg := range []string{"qodercli", "qoderclicn"} {
		directory := filepath.Join(filepath.Dir(shim), "node_modules", "@qoder-ai", pkg)
		raw, err := os.ReadFile(filepath.Join(directory, "package.json"))
		if err != nil {
			continue
		}
		var manifest struct{ Bin map[string]string }
		if json.Unmarshal(raw, &manifest) != nil {
			continue
		}
		entry := filepath.FromSlash(manifest.Bin[name])
		if !filepath.IsLocal(entry) {
			continue
		}
		path := filepath.Join(directory, entry)
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
			return path
		}
	}
	return ""
}

func qoderExchange(ctx context.Context, cmd *exec.Cmd, usage bool) (qoderReply, error) {
	var response qoderReply
	err := agentControlStream(ctx, cmd, func(in io.WriteCloser, lines *bufio.Scanner) error {
		input, target := qoderInit+"\n", "tokenmeter-initialize"
		if usage {
			input += qoderUsageRequest + "\n"
			target = "tokenmeter-usage"
		}
		if _, err := io.WriteString(in, input); err != nil {
			return errors.New("无法向 Qoder CLI 发送控制请求")
		}
		if err := in.Close(); err != nil {
			return errors.New("无法完成 Qoder CLI 控制请求")
		}
		for lines.Scan() {
			var reply struct {
				Type     string
				Response struct {
					RequestID string `json:"request_id"`
					Subtype   string
					Response  json.RawMessage
					Error     json.RawMessage
				}
			}
			if json.Unmarshal(lines.Bytes(), &reply) != nil || reply.Type != "control_response" || reply.Response.RequestID != target {
				continue
			}
			if reply.Response.Subtype != "success" {
				return qoderControlError(reply.Response.Error)
			}
			if json.Unmarshal(reply.Response.Response, &response) != nil {
				return errors.New("Qoder CLI 返回的控制响应格式无效")
			}
			return nil
		}
		if usage {
			return errors.New("Qoder CLI 未返回 Credits 额度响应")
		}
		return errors.New("Qoder CLI 未返回模型目录响应")
	})
	if ctx.Err() == context.DeadlineExceeded {
		return qoderReply{}, errors.New("Qoder CLI 读取超时")
	}
	return response, err
}

func qoderControlError(raw json.RawMessage) error {
	// Control errors can contain request headers or command output. Only project
	// known reasons into text that can be saved in the menu snapshot.
	message := strings.ToLower(string(raw))
	switch {
	case strings.Contains(message, "unauthenticated"), strings.Contains(message, "unauthorized"), strings.Contains(message, "not logged in"), strings.Contains(message, "401"):
		return errors.New("Qoder 登录已失效，请在 Qoder CLI 中重新登录")
	case strings.Contains(message, "forbidden"), strings.Contains(message, "403"):
		return errors.New("Qoder 账户没有查看该额度的权限")
	case strings.Contains(message, "too many requests"), strings.Contains(message, "429"):
		return errors.New("Qoder 限制了查询频率，请稍后再试")
	case strings.Contains(message, "timeout"), strings.Contains(message, "network"):
		return errors.New("Qoder 额度服务连接失败，请检查网络")
	default:
		return errors.New("Qoder CLI 返回控制请求失败")
	}
}

// QoderModels reads the SDK catalog without generating a model request or saving a session.
func QoderModels(ctx context.Context, e Environment) ([]QoderModel, error) {
	reply, err := qoderControl(ctx, e, false)
	if err != nil {
		return nil, err
	}
	models := make([]QoderModel, 0, len(reply.Models))
	for _, m := range reply.Models {
		m.Value = strings.TrimSpace(m.Value)
		m.ModelID = strings.TrimSpace(m.ModelID)
		m.DisplayName = strings.TrimSpace(m.DisplayName)
		m.Source = strings.TrimSpace(m.Source)
		if m.Value != "" && m.DisplayName != "" {
			models = append(models, m)
		}
	}
	if len(models) == 0 {
		return nil, errors.New("Qoder CLI 初始化响应中没有模型目录")
	}
	return models, nil
}

func collectQoder(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	reply, err := qoderControl(ctx, e, true)
	if err != nil {
		return Snapshot{}, err
	}
	return qoderSnapshot(p, reply.Usage)
}

func qoderSnapshot(p Provider, usage *qoderUsage) (Snapshot, error) {
	s := NewSnapshot(p)
	group := Group{ID: p.ID, Title: p.DisplayName, Subtitle: "Credits"}
	var parts []string
	if usage != nil {
		for _, plan := range []struct {
			id, label    string
			q            *qoderQuota
			organization bool
		}{
			{"plan", "套餐", usage.UserQuota, false}, {"addon", "加购", usage.AddOnQuota, false}, {"organization", "组织包", usage.OrgResourcePackage, true},
		} {
			if plan.q == nil {
				continue
			}
			q := *plan.q
			if plan.organization {
				q.Total = q.Cap
			}
			if q.Total == "" && q.Used == "" && q.Remaining == "" && q.Percentage == nil {
				continue
			}
			unit := strings.TrimSpace(q.Unit)
			if unit == "" || strings.EqualFold(unit, "credits") {
				unit = "Credits"
			} else {
				group.Subtitle = ""
			}
			m := Metric{ID: p.ID + "-" + plan.id, Label: plan.label, Kind: "quota", Status: "ok"}
			if q.Used != "" || q.Remaining != "" || q.Total != "" {
				m.UsedAmount = q.Used.String()
				m.RemainingAmount = q.Remaining.String()
				m.TotalAmount = q.Total.String()
				m.Unit = unit
			}
			m.UsedPercent = qoderPercent(q.Used, q.Total, q.Percentage)
			var complement *float64
			if m.UsedPercent != nil {
				v := 100 - *m.UsedPercent
				complement = &v
			}
			m.RemainingPercent = qoderPercent(q.Remaining, q.Total, complement)
			if plan.organization {
				m.Detail = qoderBreakdown(q, unit)
				if q.Available != nil && !*q.Available {
					m.Status = "warning"
					if m.Detail != "" {
						m.Detail += " · "
					}
					m.Detail += "当前不可用"
				}
			} else {
				m.Detail = qoderRingDetail(q, unit)
			}
			parts = append(parts, plan.label+qoderSummary(q, unit))
			group.Items = append(group.Items, m)
		}
	}
	if len(group.Items) == 0 {
		return Snapshot{}, errors.New("Qoder CLI 响应中没有可用的 Credits 额度字段")
	}
	if usage.IsQuotaExceeded {
		s.Status = "warning"
		s.Message = "Credits 额度已用尽"
	}
	s.Groups = []Group{group}
	s.Summary = strings.Join(parts, " · ")
	return s, nil
}
func qoderPercent(part, total json.Number, fallback *float64) *float64 {
	p, pErr := part.Float64()
	t, tErr := total.Float64()
	var percent float64
	switch {
	case pErr == nil && tErr == nil && t > 0:
		percent = p / t * 100
	case fallback != nil:
		percent = *fallback
	default:
		return nil
	}
	percent = max(0, min(100, percent))
	return &percent
}

func qoderAmountText(n json.Number) string {
	if strings.ContainsAny(n.String(), ".eE") {
		if f, err := n.Float64(); err == nil {
			return creditNumber(f)
		}
	}
	return n.String()
}

func qoderRingDetail(q qoderQuota, unit string) string {
	if q.Total != "" {
		if q.Used != "" {
			return qoderAmountText(q.Used) + " / " + qoderAmountText(q.Total) + " " + unit
		}
		total, terr := q.Total.Float64()
		remaining, rerr := q.Remaining.Float64()
		if terr == nil && rerr == nil {
			return creditNumber(max(0, total-remaining)) + " / " + qoderAmountText(q.Total) + " " + unit
		}
		return "总额 " + qoderAmountText(q.Total) + " " + unit
	}
	if q.Used != "" {
		return "已用 " + qoderAmountText(q.Used) + " " + unit
	}
	return ""
}
func qoderBreakdown(q qoderQuota, unit string) string {
	var parts []string
	for _, field := range []struct {
		label  string
		number json.Number
	}{{"已用", q.Used}, {"剩余", q.Remaining}, {"总额", q.Total}} {
		if field.number != "" {
			parts = append(parts, field.label+" "+qoderAmountText(field.number))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return strings.Join(parts, " · ") + " " + unit
}
func qoderSummary(q qoderQuota, unit string) string {
	if q.Remaining != "" {
		amount := qoderAmountText(q.Remaining)
		if q.Total != "" {
			amount += " / " + qoderAmountText(q.Total)
		}
		return "剩余 " + amount + " " + unit
	}
	if q.Used != "" && q.Total != "" {
		return "已用 " + qoderAmountText(q.Used) + " / " + qoderAmountText(q.Total) + " " + unit
	}
	return "额度"
}
