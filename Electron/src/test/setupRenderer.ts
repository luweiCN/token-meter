if (typeof document !== 'undefined' && document.getElementById('root') === null) {
  const root = document.createElement('div');
  root.id = 'root';
  document.body.append(root);
}

// jsdom 29 no longer provides window.localStorage; theme.ts reads/writes the theme
// preference through the bare `localStorage` global. Shim a minimal in-memory
// implementation (fresh per test file, matching real per-origin isolation).
if (typeof window !== 'undefined' && typeof window.localStorage === 'undefined') {
  const store = new Map<string, string>();
  const localStorageShim: Storage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => {
      store.set(key, String(value));
    },
    removeItem: (key: string) => {
      store.delete(key);
    },
    clear: () => {
      store.clear();
    },
    key: (index: number) => [...store.keys()][index] ?? null,
    get length() {
      return store.size;
    }
  };
  Object.defineProperty(window, 'localStorage', { value: localStorageShim, configurable: true });
  Object.defineProperty(globalThis, 'localStorage', { value: localStorageShim, configurable: true });
}

// uPlot touches window.matchMedia at import time (devicePixelRatio tracking); jsdom
// omits it. Shim a no-op so the chart module imports cleanly. uPlot itself is never
// constructed under jsdom (the component guards on a real canvas 2d context).
if (typeof window !== 'undefined' && typeof window.matchMedia !== 'function') {
  window.matchMedia = ((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false
  })) as typeof window.matchMedia;
}
