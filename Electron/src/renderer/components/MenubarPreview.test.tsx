// @vitest-environment jsdom

import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { MenubarPreviewBar, PREVIEW_PROVIDERS, type MenubarPreviewState } from './MenubarPreview.js';

const base: MenubarPreviewState = {
  style: 'rings',
  showName: true,
  showGlyph: true,
  showNumber: true,
  usage: 'tok',
  windowOrder: 'longFirst',
  providers: PREVIEW_PROVIDERS.map((p) => ({
    id: p.id,
    visible: p.id !== 'omp',
    glyphWindow: 'both' as const,
    numberWindow: 'both' as const
  }))
};

function onlyProviders(...ids: string[]): MenubarPreviewState['providers'] {
  return base.providers.map((p) => ({ ...p, visible: ids.includes(p.id) }));
}

describe('MenubarPreviewBar', () => {
  it('renders one cell per visible provider plus the usage tail for rings', () => {
    const { container } = render(<MenubarPreviewBar mode="dark" state={base} />);
    // 3 家可见 + 今日尾巴 = 4 个 cell
    expect(container.querySelectorAll('.mbcell').length).toBe(4);
    expect(container.querySelectorAll('svg').length).toBeGreaterThan(0);
    expect(screen.getByText('214.8M')).toBeTruthy();
  });

  it('digits style renders no glyph and honors window order', () => {
    const longFirst = render(<MenubarPreviewBar mode="dark" state={{ ...base, style: 'digits' }} />);
    expect(longFirst.container.querySelector('.mb-vbars, .mb-dots, .mb-caps, svg')).toBeNull();
    // CC 5h=62 / 7d=41：longFirst → 41 在前
    const ccLong = longFirst.container.querySelectorAll('.mbcell')[0];
    expect(ccLong.textContent).toContain('41·62');

    const shortFirst = render(
      <MenubarPreviewBar mode="dark" state={{ ...base, style: 'digits', windowOrder: 'shortFirst' }} />
    );
    const ccShort = shortFirst.container.querySelectorAll('.mbcell')[0];
    expect(ccShort.textContent).toContain('62·41');
  });

  it('sentinel collapses to a single logo when all healthy and reports the worst family otherwise', () => {
    const quiet = render(
      <MenubarPreviewBar mode="dark" state={{ ...base, style: 'sentinel', usage: 'off', providers: onlyProviders('claude') }} />
    );
    expect(quiet.container.querySelectorAll('.mb-logo').length).toBe(1);
    expect(quiet.container.querySelector('.pct')).toBeNull();

    const alerting = render(
      <MenubarPreviewBar mode="dark" state={{ ...base, style: 'sentinel', usage: 'off', providers: onlyProviders('claude', 'zhipu') }} />
    );
    // 智谱 5h 剩 8（红）是最险家
    expect(alerting.container.textContent).toContain('智谱');
    expect(alerting.container.textContent).toContain('8');
  });

  it('renders cost tail and the hidden-all placeholder', () => {
    const { container } = render(
      <MenubarPreviewBar
        mode="light"
        state={{ ...base, usage: 'cost', providers: base.providers.map((p) => ({ ...p, visible: false })) }}
      />
    );
    expect(container.textContent).toContain('$196.44');

    const empty = render(
      <MenubarPreviewBar
        mode="light"
        state={{ ...base, usage: 'off', providers: base.providers.map((p) => ({ ...p, visible: false })) }}
      />
    );
    expect(empty.container.textContent).toContain('全部隐藏');
  });

  it('per-provider number window narrows digits to the chosen window', () => {
    const { container } = render(
      <MenubarPreviewBar
        mode="dark"
        state={{
          ...base,
          style: 'digits',
          providers: base.providers.map((p) => (p.id === 'claude' ? { ...p, numberWindow: 'short' as const } : p))
        }}
      />
    );
    const cc = container.querySelectorAll('.mbcell')[0];
    expect(cc.textContent).toContain('62');
    expect(cc.textContent).not.toContain('41');
  });
});
