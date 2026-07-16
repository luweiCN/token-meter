// installed by TokenMeter
// managed by TokenMeter; reinstalling or updating the app overwrites this file.
// add custom hooks/plugins beside this file instead of editing it.
// TOKENMETER_INTEGRATION_ID=omp
// TOKENMETER_INTEGRATION_VERSION=2
// @ts-nocheck
//
// 只做生命周期上报（TokenMeter 的实时会话点亮），不做完整的运行状态机。
// 事件面与 hasUI 防护参考 ~/.omp/agent/extensions 里经过本地修订验证的
// herdr 集成（herdr 原版有未修的 bug，勿以它为准）。
// 防御式：任何失败静默，绝不影响 OMP 本体。

import { createConnection } from "node:net";

const PORT = 47731;

function send(event, sessionId, cwd) {
  if (!sessionId) return;
  try {
    const socket = createConnection({ host: "127.0.0.1", port: PORT });
    const request = {
      id: `omp-${process.pid}-${Date.now()}`,
      method: "agent.sessionEvent",
      params: {
        agent: "omp",
        event,
        sessionId: String(sessionId),
        cwd: cwd ? String(cwd) : "",
        // 扩展跑在 OMP 进程内，process.pid 即 agent 进程——start 事件靠它
        // 把同进程的旧会话置 ended（/resume、/new 切会话场景）。
        ownerPid: String(process.pid),
      },
    };
    socket.setTimeout(2000);
    socket.on("connect", () => {
      socket.write(`${JSON.stringify(request)}\n`);
    });
    socket.on("data", () => socket.destroy());
    socket.on("timeout", () => socket.destroy());
    socket.on("error", () => {});
  } catch {
    // TokenMeter 未运行时 OMP 不受任何影响。
  }
}

function sessionIdOf(ctx) {
  try {
    return ctx?.sessionManager?.getSessionId?.() ?? null;
  } catch {
    return null;
  }
}

export default function (pi) {
  let lastSessionId = null;

  const remember = (ctx) => {
    const id = sessionIdOf(ctx);
    if (id) lastSessionId = id;
    return id ?? lastSessionId;
  };

  const on = (name, handler) => {
    try {
      pi.on(name, handler);
    } catch {
      // 旧版 OMP 没有的事件名：静默跳过。
    }
  };

  on("session_start", (_event, ctx) => {
    // hasUI === false 的是无界面子会话，不算「运行中」的根会话（本地修订版结论）。
    if (ctx?.hasUI === false) return;
    send("start", remember(ctx), process.cwd());
  });

  on("session_switch", (_event, ctx) => {
    if (ctx?.hasUI === false) return;
    send("start", remember(ctx), process.cwd());
  });

  on("agent_start", (_event, ctx) => {
    send("heartbeat", remember(ctx), process.cwd());
  });

  on("agent_end", (_event, ctx) => {
    send("heartbeat", remember(ctx), process.cwd());
  });

  // 工具等待批准 = 阻塞（herdr 同语义的 tool_approval named block）；
  // 批准/拒绝后回 heartbeat 解除。
  on("tool_approval_requested", (_event, ctx) => {
    send("blocked", remember(ctx), process.cwd());
  });

  on("tool_approval_resolved", (_event, ctx) => {
    send("heartbeat", remember(ctx), process.cwd());
  });

  on("session_shutdown", (_event, ctx) => {
    // shutdown 时 ctx 可能已不可用，退回最近一次记住的会话 id。
    send("stop", remember(ctx), process.cwd());
  });
}
