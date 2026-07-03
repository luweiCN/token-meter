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
