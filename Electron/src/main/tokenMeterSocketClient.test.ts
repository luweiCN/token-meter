import net from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';

import { notifySwift, requestFullRescan, type ScanProgressEvent } from './tokenMeterSocketClient.js';

interface ListeningServer {
  port: number;
  close: () => Promise<void>;
}

const servers: net.Server[] = [];
const sockets: net.Socket[] = [];

async function listen(onConnection: (socket: net.Socket) => void): Promise<ListeningServer> {
  const server = net.createServer((socket) => {
    sockets.push(socket);
    socket.once('close', () => {
      const index = sockets.indexOf(socket);
      if (index >= 0) sockets.splice(index, 1);
    });
    onConnection(socket);
  });
  servers.push(server);

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject);
      resolve();
    });
  });

  const address = server.address();
  if (typeof address !== 'object' || address === null) {
    throw new Error('expected TCP server to bind to an ephemeral port');
  }

  return {
    port: address.port,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      })
  };
}

afterEach(async () => {
  for (const socket of sockets.splice(0)) {
    socket.destroy();
  }
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.close(() => resolve());
        })
    )
  );
});

describe('notifySwift', () => {
  it('sends a newline-terminated JSON request to the local Swift socket and resolves ok responses', async () => {
    let rawRequest = '';
    let parsedRequest: Record<string, unknown> | undefined;
    const server = await listen((socket) => {
      socket.on('data', (chunk) => {
        rawRequest += chunk.toString('utf8');
        if (!rawRequest.endsWith('\n')) return;

        parsedRequest = JSON.parse(rawRequest.trimEnd()) as Record<string, unknown>;
        socket.write(`${JSON.stringify({ id: parsedRequest.id, ok: true, result: { status: 'settingsApplied' } })}\n`);
      });
    });

    const response = await notifySwift('settingsChanged', { version: '4' }, { port: server.port, timeoutMs: 500 });

    expect(rawRequest.endsWith('\n')).toBe(true);
    expect(parsedRequest).toEqual({
      id: expect.any(String),
      method: 'settingsChanged',
      params: { version: '4' }
    });
    expect(response).toEqual({
      id: parsedRequest?.id,
      ok: true,
      result: { status: 'settingsApplied' }
    });
  });

  it('rejects Swift ok:false responses with the surfaced error message', async () => {
    const server = await listen((socket) => {
      socket.on('data', (chunk) => {
        const request = JSON.parse(chunk.toString('utf8').trimEnd()) as { id: string };
        socket.write(`${JSON.stringify({ id: request.id, ok: false, error: 'settings reload failed' })}\n`);
      });
    });

    await expect(notifySwift('settingsChanged', { version: '4' }, { port: server.port, timeoutMs: 500 })).rejects.toThrow(
      /settings reload failed/
    );
  });

  it('rejects when Swift does not answer before the timeout', async () => {
    const server = await listen(() => {
      // Keep the socket open and intentionally send no response.
    });

    await expect(notifySwift('settingsChanged', { version: '4' }, { port: server.port, timeoutMs: 25 })).rejects.toThrow(
      /timeout/i
    );
  });
});

const progressLine = (bytesDone: number, bytesTotal: number): string =>
  `${JSON.stringify({
    kind: 'scan.progress',
    filesTotal: 3,
    filesDone: 1,
    bytesTotal,
    bytesDone,
    currentRoot: 'Claude'
  })}\n`;

const finishedLine = (status: string, error?: string): string =>
  `${JSON.stringify({ kind: 'scan.finished', status, ...(error ? { error } : {}) })}\n`;

describe('requestFullRescan', () => {
  it('streams progress events line-by-line and resolves on scan.finished ok', async () => {
    const server = await listen((socket) => {
      socket.on('data', () => {
        socket.write(progressLine(50, 100));
        socket.write(progressLine(100, 100));
        socket.write(finishedLine('ok'));
      });
    });

    const events: ScanProgressEvent[] = [];
    await expect(
      requestFullRescan((event) => events.push(event), { port: server.port })
    ).resolves.toBeUndefined();

    expect(events).toEqual([
      { kind: 'scan.progress', filesTotal: 3, filesDone: 1, bytesTotal: 100, bytesDone: 50, currentRoot: 'Claude' },
      { kind: 'scan.progress', filesTotal: 3, filesDone: 1, bytesTotal: 100, bytesDone: 100, currentRoot: 'Claude' }
    ]);
  });

  it('rejects when the Swift socket closes mid-stream before scan.finished', async () => {
    const events: ScanProgressEvent[] = [];
    const server = await listen((socket) => {
      socket.on('data', () => {
        socket.write(progressLine(50, 100));
        // Drop the connection without ever sending scan.finished.
        setTimeout(() => socket.destroy(), 20);
      });
    });

    await expect(requestFullRescan((event) => events.push(event), { port: server.port })).rejects.toThrow();
    expect(events).toHaveLength(1);
  });

  it('does not reject when the server is silent for longer than 2s before the first progress line', async () => {
    // 回归 index:fullReindex 的 2 秒缺陷：首字节前的长时间沉默不得触发拒绝。
    // 空闲超时是「无数据的空闲时长」，默认 30s，远大于这里 3s 的开扫前沉默。
    const server = await listen((socket) => {
      socket.on('data', () => {
        setTimeout(() => {
          socket.write(progressLine(100, 100));
          socket.write(finishedLine('ok'));
        }, 3_000);
      });
    });

    await expect(requestFullRescan(() => {}, { port: server.port })).resolves.toBeUndefined();
  }, 10_000);

  it('rejects on idle timeout when progress stops arriving', async () => {
    const server = await listen((socket) => {
      socket.on('data', () => {
        socket.write(progressLine(10, 100));
        // Then go silent forever — the idle timer must fire.
      });
    });

    await expect(
      requestFullRescan(() => {}, { port: server.port, idleTimeoutMs: 80 })
    ).rejects.toThrow(/timeout/i);
  });

  it('rejects on a malformed JSON line instead of hanging', async () => {
    const server = await listen((socket) => {
      socket.on('data', () => {
        socket.write('this is not json\n');
      });
    });

    await expect(requestFullRescan(() => {}, { port: server.port })).rejects.toThrow();
  });
});
