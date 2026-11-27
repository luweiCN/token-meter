import { isPairURL } from '../shared/pairing.js';

// Native URL dispatch may precede window creation. Keep a pending invite only
// in this process until the trusted renderer has installed its listener.
let pending: string | null = null;
export function queueInvitation(value: unknown): boolean {
  if (!isPairURL(value)) return false;
  pending = value;
  return true;
}

export function takeInvitation(): string | null {
  const result = pending;
  pending = null;
  return result;
}
