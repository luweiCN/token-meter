# TokenMeter 公网中继

桌面、CLI 和手机可通过 HTTPS 让两台仅允许出站的设备相连。中继在内存中保存短期房间、在线设备路由和流量计数。两台设备在得到的字节流内部完成身份核验、配对与加密。中继可见连接 IP、路由公钥、时间和流量大小，设备身份私钥和用量账本保存在设备端。

## 部署

```sh
go build -trimpath -o token-meter-relay ./cmd/token-meter-relay
./token-meter-relay --listen 127.0.0.1:47739
```

在 HTTPS 反向代理上将 `GET /healthz` 和 `GET /v1/connect` 转到上述地址。后者使用 HTTP/1.1 WebSocket Upgrade，保留原始 Host、Upgrade、Connection 和 Sec-WebSocket-Protocol。反向代理的读取空闲时限可设为 90 秒，服务每 25 秒发送一次控制链路心跳。部署在 URL 前缀下时，由代理剥离前缀再转发。

如要按外部客户端 IP 限流，先让回环反向代理覆盖 X-Real-IP 或 X-Forwarded-For 为该连接的单个真实 IP，再为中继设置 `--trust-loopback-proxy`。公网客户端使用 HTTPS，回环 HTTP 入口可供本机开发和测试。

以下参数适用于与其他服务共享的小型服务器。速率和总量均统计双向转发。

```sh
./token-meter-relay --listen 127.0.0.1:47739 --trust-loopback-proxy \
  --window-mib 128 --ip-window-mib 64 --egress-kib-per-sec 256
```

`GET /healthz` 正常时返回 `200` 和 `ok`。在已授权的自建入口上可用临时生成的两个设备身份验证双向字节传输。测试结束即关闭两条出站连接。

```sh
TOKENMETER_TEST_RELAY=https://relay.example.com go test -count=1 -run '^TestPublicEndpoint$' ./internal/relay
```

## 协议

WebSocket 子协议为 `tokenmeter.relay.v1`。初始控制帧使用 JSON，单帧上限为 2 KiB。服务先发送 `{"type":"challenge","nonce":"…"}`，其中 nonce 是 32 个随机字节的无填充 base64url。设备随后发送一项操作。除公开查询房间外，设备用 Ed25519 签名，其 ID 为 32 字节公钥的小写十六进制，proof 为无填充 base64url。

签名原文按顺序连接协议名、请求 URL 的小写 Host（含显式端口）、nonce、type、id、target、room、ticket，各字段之间恰好一个零字节，缺省字段记为空串。签名只适用于本条连接的一次操作。

| 操作 | 参数 | 成功结果 |
| --- | --- | --- |
| `listen` | id、proof | 收到 ok 后保持连接。中继通过 offer 发送一次性 ticket。 |
| `dial` | id、target、proof | 等候对端连接后收到 ok，再作为二进制字节流使用。 |
| `answer` | id、ticket、proof | 接收方建立第二条出站连接，收到 ok 后接收对应字节流。 |
| `create` | id、room、proof | 保留房间十分钟，仅接收公开房间号。 |
| `resolve` | room | 返回 `{"type":"ok","id":"…"}`。 |
| `cancel` | id、room、proof | 房间拥有者可提前取消邀请。 |

room 为 6 到 16 位小写 ASCII 字母或数字。客户端在本地生成的配对口令通过用户的邀请渠道交给另一台设备。中继仅收到用于寻址的 room。业务响应为 `{"type":"ok"}` 或 `{"type":"error","error":"…"}`。错误码包括 `busy`、`denied`、`exists`、`notfound` 和 `offline`。

二进制消息上限为 64 KiB。一条数据流的发送顺序必须保持，跨帧组合后为普通可靠字节流。已配对的设备在流内建立固定对端公钥的 TLS 连接。控制连接丢失后重新监听并使用带抖动的退避。服务重启会清除未完成的邀请，已配对的设备仍保存本机信任关系。
