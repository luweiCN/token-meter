export type PairRole = 'peer' | 'viewer';

export type PairRequest =
  | { mode: 'create'; role: PairRole }
  | { mode: 'join'; invitation: string; role: PairRole };

export type PairEvent =
  | { state: 'connecting' }
  | { state: 'waiting'; name: string; role: PairRole; verification?: string }
  | { state: 'invitation'; code: string; url: string; expiresAt: string; role: PairRole }
  | { state: 'confirm'; name: string; id: string; role: PairRole; verification: string; canApprove: boolean }
  | { state: 'paired'; name: string; id: string; role: PairRole }
  | { state: 'error' | 'expired' | 'rejected' | 'cancelled'; message: string };

export type TrustedDevice = {
  id: string;
  name: string;
  role: PairRole | 'source';
  lastSync?: number;
};

export function isPairURL(value: unknown): value is string {
  return typeof value === 'string' && value.startsWith('tokenmeter://pair/')
    && !/[\u0000-\u0020\u007f]/.test(value)
    && /^tokenmeter:\/\/pair\/[2-9A-HJ-NP-Z]{6}#v1\.[A-Za-z0-9_-]{32}$/i.test(value)
    && value.includes('#v1.');
}

export function isPairInvitation(value: unknown): value is string {
  return isPairURL(value) || (typeof value === 'string' && value.length <= 512 &&
    /^[2-9A-HJ-NP-Z]{12}$/i.test(value.replace(/[ -]/g, '')));
}

export function isPairRole(value: unknown): value is PairRole {
  return value === 'peer' || value === 'viewer';
}

export function isDeviceID(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function safeText(value: unknown, max: number): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= max
    && !/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/.test(value);
}

export function isPairEvent(value: unknown): value is PairEvent {
  if (!isRecord(value)) return false;
  switch (value.state) {
    case 'connecting': return true;
    case 'invitation':
      return isPairInvitation(value.code) && !isPairURL(value.code) && isPairURL(value.url)
        && typeof value.expiresAt === 'string' && Number.isFinite(Date.parse(value.expiresAt)) && isPairRole(value.role);
    case 'waiting': return safeText(value.name, 255) && isPairRole(value.role);
    case 'confirm':
      if (typeof value.canApprove !== 'boolean' || typeof value.verification !== 'string' || !/^\d{3} ?\d{3}$/.test(value.verification)) return false;
      return isDeviceID(value.id) && safeText(value.name, 255) && isPairRole(value.role);
    case 'paired': return isDeviceID(value.id) && safeText(value.name, 255) && isPairRole(value.role);
    case 'error':
    case 'expired':
    case 'rejected':
    case 'cancelled': return safeText(value.message, 500);
    default: return false;
  }
}

export function isTrustedDevice(value: unknown): value is TrustedDevice {
  return isRecord(value) && isDeviceID(value.id) && safeText(value.name, 255)
    && (isPairRole(value.role) || value.role === 'source')
    && (value.lastSync === undefined || (typeof value.lastSync === 'number' && Number.isSafeInteger(value.lastSync)));
}

export interface PairingAPI {
  start(id: string, request: PairRequest): Promise<void>;
  decide(id: string, approve: boolean): Promise<void>;
  cancel(id: string): Promise<void>;
  copy(id: string, field: 'code' | 'url'): Promise<void>;
  onUpdate(callback: (id: string, event: PairEvent) => void): () => void;
  list(): Promise<TrustedDevice[]>;
  remove(id: string): Promise<void>;
  takeInvitation(): Promise<string | null>;
  onInvitation(callback: () => void): () => void;
}
