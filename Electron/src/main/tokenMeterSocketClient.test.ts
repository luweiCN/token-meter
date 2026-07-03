import net from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';

import { notifySwift } from './tokenMeterSocketClient.js';

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
