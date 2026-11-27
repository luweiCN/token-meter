let pending = false;

export function queueSettingsOpen(): void {
  pending = true;
}

export function takeSettingsOpen(): boolean {
  const requested = pending;
  pending = false;
  return requested;
}
