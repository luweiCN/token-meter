package account

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
	"time"
)

func grokBillingJSON(data []byte, p Provider) (Snapshot, error) {
	var root map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if decoder.Decode(&root) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return Snapshot{}, errGrokNoQuota
	}
	config, _ := root["config"].(map[string]any)
	base := []map[string]any{root, config}
	var pct *float64
	for _, item := range base {
		if pct = grokNumber(item["creditUsagePercent"], item["usedPercent"], item["usagePercent"]); pct != nil {
			break
		}
	}
	rootUsage, _ := root["usage"].(map[string]any)
	configUsage, _ := config["usage"].(map[string]any)
	cap := grokCents(root["monthlyLimit"], config["monthlyLimit"])
	used := grokCents(rootUsage["includedUsed"], root["used"], config["used"], configUsage["includedUsed"])
	onDemandUsed := grokCents(rootUsage["onDemandUsed"], root["onDemandUsed"], config["onDemandUsed"], configUsage["onDemandUsed"])
	onDemandCap := grokCents(root["onDemandCap"], config["onDemandCap"])
	prepaid := grokCents(root["prepaidBalance"], config["prepaidBalance"])
	if used == nil {
		total := grokCents(rootUsage["totalUsed"], root["totalUsed"], configUsage["totalUsed"])
		if total != nil {
			// totalUsed includes on-demand charges in the legacy ACP breakdown.
			if onDemandUsed == nil {
				used = total
			} else if *total >= *onDemandUsed {
				included := *total - *onDemandUsed
				used = &included
			}
		}
	}
	percentFromBudget := pct == nil && used != nil && cap != nil && *cap > 0
	if percentFromBudget {
		value := float64(*used) / float64(*cap) * 100
		pct = &value
	}
	period := func(top, nested string) time.Time {
		for _, item := range base {
			cycle, _ := item["billingCycle"].(map[string]any)
			current, _ := item["currentPeriod"].(map[string]any)
			for _, value := range []any{cycle[top], current[nested], item[top]} {
				s, _ := value.(string)
				if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
					return t
				}
			}
		}
		return time.Time{}
	}
	s := NewSnapshot(p)
	amounts := Group{ID: p.ID + "-billing", Title: "账户资金"}
	if pct != nil {
		s = grokBillingSnapshot(p, *pct, period("billingPeriodStart", "start"), period("billingPeriodEnd", "end"))
	}
	if percentFromBudget {
		window := &s.Groups[0].Items[0]
		window.UsedAmount, window.TotalAmount, window.Unit = grokUSD(used), grokUSD(cap), "USD"
	} else if used != nil || cap != nil {
		// The published percentage can describe a weekly pool while monthlyLimit describes money.
		amounts.Items = append(amounts.Items, grokSpend(p.ID+"-included", "套餐预算", used, cap))
	}
	if onDemandUsed != nil || onDemandCap != nil {
		amounts.Items = append(amounts.Items, grokSpend(p.ID+"-on-demand", "按量花费", onDemandUsed, onDemandCap))
	}
	if prepaid != nil {
		balance := grokUSD(prepaid)
		amounts.Items = append(amounts.Items, Metric{ID: p.ID + "-prepaid", Label: "预付余额", Kind: "balance", Status: "ok",
			RemainingAmount: balance, Unit: "USD", Detail: "$" + balance})
	}
	if len(amounts.Items) > 0 {
		s.Groups = append(s.Groups, amounts)
	}
	if len(s.Groups) == 0 {
		return Snapshot{}, errGrokNoQuota
	}
	return s, nil
}

// xAI's typed Cent.val is a signed integer count of USD cents. An empty Cent
// object encodes proto3 zero; a missing or malformed object does not.
func grokCents(values ...any) *int64 {
	for _, value := range values {
		if obj, ok := value.(map[string]any); ok {
			if len(obj) == 0 {
				return new(int64)
			}
			value = obj["val"]
			if value == nil {
				value = obj["value"]
			}
		}
		var decimal string
		switch value := value.(type) {
		case json.Number:
			decimal = value.String()
		case string:
			decimal = value
		default:
			continue
		}
		if n, err := strconv.ParseInt(decimal, 10, 64); err == nil && n >= 0 {
			return &n
		}
	}
	return nil
}

func grokUSD(cents *int64) string {
	if cents == nil {
		return ""
	}
	return fmt.Sprintf("%d.%02d", *cents/100, *cents%100)
}

func grokSpend(id, label string, used, cap *int64) Metric {
	m := Metric{ID: id, Label: label, Kind: "quota", Status: "ok", UsedAmount: grokUSD(used), TotalAmount: grokUSD(cap), Unit: "USD"}
	var description []string
	if used != nil {
		description = append(description, "已用 $"+m.UsedAmount)
	}
	if cap != nil {
		description = append(description, "上限 $"+m.TotalAmount)
	}
	m.Detail = strings.Join(description, " · ")
	return m
}

func grokNumber(values ...any) *float64 {
	for _, v := range values {
		var number float64
		switch x := v.(type) {
		case json.Number:
			n, err := x.Float64()
			if err != nil {
				continue
			}
			number = n
		case string:
			n, err := strconv.ParseFloat(x, 64)
			if err != nil {
				continue
			}
			number = n
		case map[string]any:
			if n := grokNumber(x["val"], x["value"]); n != nil {
				return n
			}
			continue
		default:
			continue
		}
		if !math.IsNaN(number) && !math.IsInf(number, 0) {
			return &number
		}
	}
	return nil
}

func grokBillingSnapshot(p Provider, pct float64, start, end time.Time) Snapshot {
	label, minutes := "7d", 10080
	if !start.IsZero() && !end.IsZero() {
		days := int(end.Sub(start).Hours() / 24)
		if days >= 27 && days <= 33 {
			label, minutes = "30d", 43200
		}
	}
	used := max(0, min(100, pct))
	left := 100 - used
	m := Metric{ID: p.ID + "-" + label, Label: label, Kind: "quota", Status: "ok", UsedPercent: &used, RemainingPercent: &left, WindowDurationMinutes: &minutes}
	if !end.IsZero() {
		m.ResetAt = end.UTC().Format(time.RFC3339)
		seconds := max(0, int64(time.Until(end).Seconds()))
		switch {
		case seconds >= 86400:
			m.ResetText = fmt.Sprintf("%dd%dh", seconds/86400, seconds%86400/3600)
		case seconds >= 3600:
			m.ResetText = fmt.Sprintf("%dh%dm", seconds/3600, seconds%3600/60)
		default:
			m.ResetText = fmt.Sprintf("%dm", seconds/60)
		}
	}
	s := NewSnapshot(p)
	s.Summary = label + " " + creditNumber(left) + "%"
	s.Groups = []Group{{ID: p.ID, Title: p.DisplayName, Items: []Metric{m}}}
	return s
}

// gRPC-Web puts the final server status in a trailer frame, even for HTTP 200.
func grokGRPCStatus(s string) error {
	switch strings.TrimSpace(s) {
	case "", "0":
		return nil
	case "16", "7":
		return errGrokLogin
	default:
		return errors.New("Grok 账单服务未返回额度")
	}
}

func grokGRPCMessage(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, errGrokNoQuota
	}
	if data[0] != 0 && data[0] != 0x80 {
		// Some clients expose the decoded protobuf body instead of gRPC-Web frames.
		return data, nil
	}
	var message []byte
	for len(data) > 0 {
		if len(data) < 5 {
			return nil, errGrokNoQuota
		}
		flag := data[0]
		size := uint64(binary.BigEndian.Uint32(data[1:5]))
		data = data[5:]
		if size > uint64(len(data)) {
			return nil, errGrokNoQuota
		}
		frame := data[:size]
		data = data[size:]
		switch flag {
		case 0:
			if message != nil {
				return nil, errGrokNoQuota
			}
			message = frame
		case 0x80:
			for line := range bytes.SplitSeq(frame, []byte("\n")) {
				key, value, ok := strings.Cut(string(line), ":")
				if ok && strings.EqualFold(key, "grpc-status") {
					if err := grokGRPCStatus(value); err != nil {
						return nil, err
					}
				}
			}
		default:
			return nil, errGrokNoQuota
		}
	}
	if len(message) == 0 {
		return nil, errGrokNoQuota
	}
	return message, nil
}

type grokProtoField struct {
	wire   uint64
	number uint64
	data   []byte
}

func grokProtoFields(data []byte) (map[uint64]grokProtoField, error) {
	fields := make(map[uint64]grokProtoField)
	for len(data) > 0 {
		tag, n := binary.Uvarint(data)
		if n <= 0 || tag>>3 == 0 {
			return nil, errGrokNoQuota
		}
		data = data[n:]
		field := grokProtoField{wire: tag & 7}
		var size uint64
		switch field.wire {
		case 0:
			v, n := binary.Uvarint(data)
			if n <= 0 {
				return nil, errGrokNoQuota
			}
			field.number = v
			data = data[n:]
		case 1:
			size = 8
		case 2:
			v, n := binary.Uvarint(data)
			if n <= 0 {
				return nil, errGrokNoQuota
			}
			size = v
			data = data[n:]
		case 5:
			size = 4
		default:
			return nil, errGrokNoQuota
		}
		if size > uint64(len(data)) {
			return nil, errGrokNoQuota
		}
		field.data = data[:size]
		data = data[size:]
		// Only the credit and billing-period tags are part of this projection.
		if tag>>3 <= 5 {
			fields[tag>>3] = field
		}
	}
	return fields, nil
}

func grokBillingGRPC(data []byte, p Provider) (Snapshot, error) {
	payload, err := grokGRPCMessage(data)
	if err != nil {
		return Snapshot{}, err
	}
	fields, err := grokProtoFields(payload)
	if err != nil {
		return Snapshot{}, err
	}
	if wrapper := fields[1]; wrapper.wire == 2 {
		fields, err = grokProtoFields(wrapper.data)
		if err != nil {
			return Snapshot{}, err
		}
	}
	usage := fields[1]
	if usage.wire != 5 || len(usage.data) != 4 {
		return Snapshot{}, errGrokNoQuota
	}
	pct := float64(math.Float32frombits(binary.LittleEndian.Uint32(usage.data)))
	if math.IsNaN(pct) || math.IsInf(pct, 0) {
		return Snapshot{}, errGrokNoQuota
	}
	if pct <= 1 {
		pct *= 100
	}
	pct = math.Round(pct*10) / 10
	var reset time.Time
	for _, tag := range []uint64{5, 4} {
		if fields[tag].wire != 2 {
			continue
		}
		stamp, err := grokProtoFields(fields[tag].data)
		if err != nil {
			return Snapshot{}, err
		}
		sec, found := stamp[1]
		nanos := stamp[2]
		if found && sec.wire == 0 && sec.number <= 253402300799 && nanos.wire == 0 && nanos.number < 1_000_000_000 {
			reset = time.Unix(int64(sec.number), int64(nanos.number))
			break
		}
	}
	return grokBillingSnapshot(p, pct, time.Time{}, reset), nil
}
