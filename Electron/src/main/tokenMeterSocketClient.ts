import { randomUUID } from 'node:crypto';
import net from 'node:net';

export interface TokenMeterSocketOptions {
  port?: number;
  timeoutMs?: number;
}

export interface TokenMeterSocketResponse {
  id: string;
  ok: boolean;
  result?: Record<string, string>;
  error?: string;
}

export function notifySwift(
  method: string,
  params: Record<string, string> = {},
  options: TokenMeterSocketOptions = {}
): Promise<TokenMeterSocketResponse> {
  const port = options.port ?? 47731;
  const timeoutMs = options.timeoutMs ?? 2_000;

  return new Promise<TokenMeterSocketResponse>((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    const request = `${JSON.stringify({ id: randomUUID(), method, params })}\n`;
    let responseBuffer = '';
    let settled = false;
    const settle = (callback: () => void) => {
      if (settled) return;
      settled = true;
      socket.removeAllListeners();
      socket.destroy();
      callback();
    };

    socket.setTimeout(timeoutMs);
    socket.on('connect', () => {
      socket.write(request);
    });
    socket.on('data', (data) => {
      responseBuffer += data.toString('utf8');
      if (!responseBuffer.includes('\n')) return;

      const [line] = responseBuffer.split('\n', 1);
      settle(() => {
        try {
          const response = JSON.parse(line) as TokenMeterSocketResponse;
          if (!response.ok) {
            reject(new Error(response.error ?? 'TokenMeter Swift IPC returned an error'));
            return;
          }
          resolve(response);
        } catch (error) {
          reject(error);
        }
      });
    });
    socket.on('timeout', () => {
      settle(() => {
        reject(new Error('TokenMeter Swift IPC timeout'));
      });
    });
    socket.on('error', (error) => {
      settle(() => {
        reject(error);
      });
    });
  });
}

export interface SwiftEventLine {
  kind: string;
  [key: string]: string;
}

/**
 * 订阅 Swift 端的事件推送（agent.sessionEvent / data.changed）：长连接收行，
 * 断线按 2s→30s 指数退避重连。返回停止函数。订阅确认 ack（IPCResponse 形状，
 * 无 kind 字段）与坏行都静默跳过。
 */
export function subscribeEvents(
  onEvent: (event: SwiftEventLine) => void,
  options: TokenMeterSocketOptions = {}
): () => void {
  const port = options.port ?? 47731;
  let stopped = false;
  let socket: net.Socket | null = null;
  let retryDelayMs = 2_000;
  let retryTimer: NodeJS.Timeout | null = null;

  const scheduleReconnect = () => {
    if (stopped || retryTimer) return;
    retryTimer = setTimeout(() => {
      retryTimer = null;
      retryDelayMs = Math.min(retryDelayMs * 2, 30_000);
      connect();
    }, retryDelayMs);
  };

  const connect = () => {
    if (stopped) return;
    let buffer = '';
    socket = net.createConnection({ host: '127.0.0.1', port });
    socket.on('connect', () => {
      retryDelayMs = 2_000;
      socket?.write(`${JSON.stringify({ id: randomUUID(), method: 'events.subscribe' })}\n`);
    });
    socket.on('data', (data) => {
      buffer += data.toString('utf8');
      if (buffer.length > MAX_STREAM_BUFFER_BYTES) {
        socket?.destroy();
        return;
      }
      let newlineIndex = buffer.indexOf('\n');
      while (newlineIndex >= 0) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        if (line) {
          try {
            const parsed = JSON.parse(line) as SwiftEventLine;
            if (parsed.kind) onEvent(parsed);
          } catch {
            // 坏行静默跳过——推送流的健壮性优先于告警。
          }
        }
        newlineIndex = buffer.indexOf('\n');
      }
    });
    socket.on('error', () => {});
    socket.on('close', () => {
      socket = null;
      scheduleReconnect();
    });
  };

  connect();

  return () => {
    stopped = true;
    if (retryTimer) clearTimeout(retryTimer);
    socket?.destroy();
  };
}

export interface ScanProgressEvent {
  kind: 'scan.progress';
  filesTotal: number;
  filesDone: number;
  bytesTotal: number;
  bytesDone: number;
  currentRoot: string;
}

export interface RequestFullRescanOptions {
  port?: number;
  idleTimeoutMs?: number;
}

// 防御性缓冲上限：一个作恶/发疯的 server 不断塞无换行的数据，不能把内存撑爆。
const MAX_STREAM_BUFFER_BYTES = 1_048_576;

/**
 * 全量重扫是流式的：Swift 端逐条发 `scan.progress` 行，末尾一条 `scan.finished`。
 * 与 `notifySwift` 的一问一答不同，这里读多行；超时是**空闲超时**（无数据的空闲时长），
 * 不是总时长——进度至少每 0.5% 来一条，30s 空闲足够宽松，而首字节前的长时间沉默也不会误触发。
 */
export function requestFullRescan(
  onProgress: (event: ScanProgressEvent) => void,
  options: RequestFullRescanOptions = {}
): Promise<void> {
  const port = options.port ?? 47731;
  const idleTimeoutMs = options.idleTimeoutMs ?? 30_000;

  return new Promise<void>((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    const request = `${JSON.stringify({ id: randomUUID(), method: 'scan.requestFull' })}\n`;
    let buffer = '';
    let settled = false;
    const settle = (callback: () => void) => {
      if (settled) return;
      settled = true;
      socket.removeAllListeners();
      socket.destroy();
      callback();
    };

    socket.setTimeout(idleTimeoutMs);
    socket.on('connect', () => {
      socket.write(request);
    });
    socket.on('data', (data) => {
      buffer += data.toString('utf8');
      if (buffer.length > MAX_STREAM_BUFFER_BYTES) {
        settle(() => reject(new Error('TokenMeter Swift IPC stream exceeded buffer limit')));
        return;
      }

      let newlineIndex = buffer.indexOf('\n');
      while (newlineIndex >= 0) {
        const rawLine = buffer.slice(0, newlineIndex);
        buffer = buffer.slice(newlineIndex + 1);

        const trimmed = rawLine.trim();
        if (trimmed.length > 0) {
          let message: { kind?: string; status?: string; error?: string };
          try {
            message = JSON.parse(trimmed) as typeof message;
          } catch (error) {
            settle(() => reject(error instanceof Error ? error : new Error('malformed scan stream line')));
            return;
          }

          if (message.kind === 'scan.progress') {
            onProgress(message as unknown as ScanProgressEvent);
          } else if (message.kind === 'scan.finished') {
            if (message.status === 'ok') {
              settle(() => resolve());
            } else {
              settle(() => reject(new Error(message.error ?? 'TokenMeter full rescan failed')));
            }
            return;
          }
        }

        newlineIndex = buffer.indexOf('\n');
      }
    });
    socket.on('timeout', () => {
      settle(() => reject(new Error('TokenMeter Swift IPC timeout')));
    });
    socket.on('close', () => {
      settle(() => reject(new Error('TokenMeter Swift IPC closed before scan finished')));
    });
    socket.on('error', (error) => {
      settle(() => reject(error));
    });
  });
}
