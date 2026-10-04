const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
if (!['read', 'consume'].includes(input.operation)) process.exit(1);

function identity() {
  try {
    const auth = JSON.parse(fs.readFileSync(path.join(process.env.CODEX_HOME, 'auth.json'), 'utf8'));
    const account = auth.tokens?.account_id;
    const subject = JSON.parse(Buffer.from(auth.tokens?.id_token.split('.')[1], 'base64url')).sub;
    if (typeof account !== 'string' || !account || typeof subject !== 'string' || !subject) return null;
    return crypto.createHash('sha256').update(`${account}\0${subject}`).digest('hex');
  } catch { return null; }
}

// Older servers can silently ignore unknown fields. Confirm this installed binary
// supports selecting a credit before it can receive a consumption request.
function verifyCreditSelection() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tokenmeter-codex-schema-'));
  try {
    execFileSync('codex', ['app-server', 'generate-json-schema', '--out', directory], { timeout: 5000, stdio: 'ignore' });
    const schema = JSON.parse(fs.readFileSync(path.join(directory, 'v2', 'ConsumeAccountRateLimitResetCreditParams.json'), 'utf8'));
    if (!schema.properties?.creditId || !schema.properties?.idempotencyKey) throw new Error('Unsupported reset API');
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
}

let child;
let finished = false;
const pending = new Map();
const timer = setTimeout(() => finish(1), 25_000);
function finish(code, value) {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  if (value !== undefined) process.stdout.write(JSON.stringify(value));
  child?.kill('SIGTERM');
  process.exit(code);
}
process.on('SIGTERM', () => finish(1));
process.on('SIGINT', () => finish(1));

async function main() {
  if (input.operation === 'consume') {
    if (![input.creditID, input.idempotencyKey, input.accountFingerprint].every(value => typeof value === 'string' && value.trim())) throw new Error('Invalid request');
    try { verifyCreditSelection(); }
    catch { return finish(0, { error: 'unsupportedResetAPI' }); }
  }
  const initialIdentity = identity();
  child = spawn('codex', ['app-server', '--listen', 'stdio://'], { stdio: ['pipe', 'pipe', 'ignore'] });
  child.on('error', () => finish(1));
  child.on('exit', () => finish(1));
  child.stdin.on('error', () => finish(1));
  let buffer = '';
  child.stdout.on('data', chunk => {
    buffer += chunk.toString('utf8');
    if (buffer.length > 4 * 1024 * 1024) return finish(1);
    for (;;) {
      const index = buffer.indexOf('\n');
      if (index < 0) break;
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      let message;
      try { message = JSON.parse(line); } catch { return finish(1); }
      const waiter = pending.get(message.id);
      if (!waiter) continue;
      pending.delete(message.id);
      if (message.error) waiter.reject(new Error('Codex request failed'));
      else waiter.resolve(message.result);
    }
  });
  let nextID = 0;
  function request(method, params) {
    return new Promise((resolve, reject) => {
      const id = nextID++;
      pending.set(id, { resolve, reject });
      child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
    });
  }
  await request('initialize', { clientInfo: { name: 'token_meter', title: 'TokenMeter', version: input.clientVersion }, capabilities: { experimentalApi: true } });
  child.stdin.write(`${JSON.stringify({ method: 'initialized', params: {} })}\n`);
  const account = await request('account/read', { refreshToken: false });
  const limits = await request('account/rateLimits/read', null);
  const fingerprint = account?.account?.type === 'chatgpt' && initialIdentity === identity() ? initialIdentity : null;
  if (input.operation === 'read') return finish(0, { accountFingerprint: fingerprint, limits });

  if (!fingerprint || fingerprint !== input.accountFingerprint) return finish(0, { error: 'accountChanged' });
  const credit = limits?.rateLimitResetCredits?.credits?.find(value => value.id === input.creditID);
  if (!credit || credit.status !== 'available') return finish(0, { outcome: 'noCredit' });
  const remaining = credit.expiresAt - Date.now() / 1000;
  const leadTime = Number(input.maxRemainingSeconds);
  if (credit.resetType !== 'codexRateLimits' || !Number.isFinite(leadTime) || leadTime <= 0 || !(remaining > 0 && remaining <= leadTime)) return finish(0, { error: 'creditNotEligible' });
  if (identity() !== fingerprint) return finish(0, { error: 'accountChanged' });
  const result = await request('account/rateLimitResetCredit/consume', { creditId: input.creditID, idempotencyKey: input.idempotencyKey });
  finish(0, result);
}

main().catch(() => finish(1));
