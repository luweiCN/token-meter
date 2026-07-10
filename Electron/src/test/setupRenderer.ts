if (typeof document !== 'undefined' && document.getElementById('root') === null) {
  const root = document.createElement('div');
  root.id = 'root';
  document.body.append(root);
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
