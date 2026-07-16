// @vitest-environment jsdom

import { fireEvent, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';

import { DateRangePicker, MultiSelect, Pager, Select } from './ui.js';

describe('Select', () => {
  const options = [
    { value: 1, label: '甲项目' },
    { value: 2, label: '乙项目' }
  ];

  it('opens on click, picks an option, and reports the change', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<Select ariaLabel="按项目筛选" value={null} placeholder="全部项目" options={options} onChange={onChange} />);

    const trigger = screen.getByRole('button', { name: '按项目筛选' });
    expect(trigger.textContent).toContain('全部项目');

    await user.click(trigger);
    await user.click(screen.getByRole('option', { name: '乙项目' }));

    expect(onChange).toHaveBeenCalledWith(2);
    expect(screen.queryByRole('listbox')).toBeNull();   // 选完即收起
  });

  it('shows the current label, offers the placeholder as a clear option, and closes on outside click', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <div>
        <span>页面其他地方</span>
        <Select ariaLabel="按项目筛选" value={1} placeholder="全部项目" options={options} onChange={onChange} />
      </div>
    );

    expect(screen.getByRole('button', { name: '按项目筛选' }).textContent).toContain('甲项目');

    await user.click(screen.getByRole('button', { name: '按项目筛选' }));
    expect(screen.getByRole('option', { name: '甲项目' }).getAttribute('aria-selected')).toBe('true');

    // 选「全部项目」= 清除筛选（onChange(null)）。
    await user.click(screen.getByRole('option', { name: '全部项目' }));
    expect(onChange).toHaveBeenCalledWith(null);

    await user.click(screen.getByRole('button', { name: '按项目筛选' }));
    fireEvent.mouseDown(screen.getByText('页面其他地方'));
    expect(screen.queryByRole('listbox')).toBeNull();   // 点外关闭
  });
});

describe('MultiSelect', () => {
  const options = [
    { value: 1, label: '甲项目' },
    { value: 2, label: '乙项目' },
    { value: 3, label: '丙工程' }
  ];

  it('toggles selections, filters options by search, and summarizes the button label', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    const { rerender } = render(
      <MultiSelect ariaLabel="按项目筛选" values={[]} allLabel="全部项目" options={options} onChange={onChange} />
    );
    expect(screen.getByRole('button', { name: '按项目筛选' }).textContent).toContain('全部项目');

    await user.click(screen.getByRole('button', { name: '按项目筛选' }));
    // 浮层内搜索：只剩匹配项。
    await user.type(screen.getByPlaceholderText('搜索…'), '项目');
    expect(screen.queryByRole('option', { name: /丙工程/ })).toBeNull();

    await user.click(screen.getByRole('option', { name: /乙项目/ }));
    expect(onChange).toHaveBeenCalledWith([2]);

    // 已选两项：触发器徽记显示选中数（设计稿 E：标签 + cnt 徽记）；浮层底部提供清除。
    rerender(
      <MultiSelect ariaLabel="按项目筛选" values={[1, 2]} allLabel="全部项目" options={options} onChange={onChange} />
    );
    // 浮层因点选不自动关闭,仍开着;徽记与底部「清除」都可直接断言。
    const trigger = screen.getByRole('button', { name: '按项目筛选' });
    expect(trigger.querySelector('.cnt')?.textContent).toBe('2');
    await user.click(screen.getByRole('button', { name: '清除' }));
    expect(onChange).toHaveBeenCalledWith([]);
  });

  it('selects every option via the footer bulk action', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <MultiSelect ariaLabel="按项目筛选" values={[1]} allLabel="全部项目" options={options} onChange={onChange} />
    );

    await user.click(screen.getByRole('button', { name: '按项目筛选' }));
    await user.click(screen.getByRole('button', { name: '全选' }));

    expect(onChange).toHaveBeenCalledWith([1, 2, 3]);
  });

  it('clears selections via the inline icon on the trigger', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(
      <MultiSelect ariaLabel="按项目筛选" values={[1]} allLabel="全部项目" options={options} onChange={onChange} />
    );

    await user.click(screen.getByRole('button', { name: '清除项目筛选' }));

    expect(onChange).toHaveBeenCalledWith([]);
    expect(screen.queryByRole('listbox')).toBeNull();
  });
});

describe('DateRangePicker', () => {
  it('offers quick ranges and reports a today range', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<DateRangePicker ariaLabel="按日期筛选" value={null} onChange={onChange} />);

    expect(screen.getByRole('button', { name: '按日期筛选' }).textContent).toContain('全部时间');

    await user.click(screen.getByRole('button', { name: '按日期筛选' }));
    await user.click(screen.getByRole('button', { name: '今天' }));

    const pad = (n: number) => String(n).padStart(2, '0');
    const now = new Date();
    const today = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    expect(onChange).toHaveBeenCalledWith({ from: today, to: today });
  });

  it('previews the hovered span after picking a start day', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<DateRangePicker ariaLabel="按日期筛选" value={null} onChange={onChange} />);

    await user.click(screen.getByRole('button', { name: '按日期筛选' }));
    await user.click(screen.getByRole('button', { name: '5' }));
    fireEvent.mouseEnter(screen.getByRole('button', { name: '8' }));

    // 5~8 整段亮起：端点实色（rs/re），预选中段用更浅的 preview（设计稿 F）。
    expect(screen.getByRole('button', { name: '5' }).className).toContain('rs');
    expect(screen.getByRole('button', { name: '6' }).className).toContain('preview');
    expect(screen.getByRole('button', { name: '7' }).className).toContain('preview');
    expect(screen.getByRole('button', { name: '8' }).className).toContain('re');
    expect(onChange).not.toHaveBeenCalled();          // 预览不落值
  });

  it('clears the selected range via the inline icon without reopening the popover', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<DateRangePicker ariaLabel="按日期筛选" value={{ from: '2026-07-01', to: '2026-07-10' }} onChange={onChange} />);

    await user.click(screen.getByRole('button', { name: '清除日期筛选' }));

    expect(onChange).toHaveBeenCalledWith(null);
    expect(screen.queryByRole('dialog')).toBeNull();   // 清除不带出浮层
  });

  it('picks a custom range from the calendar with automatic ordering', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<DateRangePicker ariaLabel="按日期筛选" value={null} onChange={onChange} />);

    await user.click(screen.getByRole('button', { name: '按日期筛选' }));
    // 先点 20 号再点 5 号：范围自动交换成 5→20。
    await user.click(screen.getByRole('button', { name: '20' }));
    await user.click(screen.getByRole('button', { name: '5' }));

    const now = new Date();
    const pad = (n: number) => String(n).padStart(2, '0');
    const ym = `${now.getFullYear()}-${pad(now.getMonth() + 1)}`;
    expect(onChange).toHaveBeenCalledWith({ from: `${ym}-05`, to: `${ym}-20` });
  });
});

describe('Pager', () => {
  it('renders nothing for a single page and pages within bounds otherwise', async () => {
    const user = userEvent.setup();
    const onPage = vi.fn();
    const { rerender } = render(<Pager page={1} pageCount={1} onPage={onPage} />);
    expect(screen.queryByRole('navigation')).toBeNull();

    rerender(<Pager page={1} pageCount={3} onPage={onPage} />);
    expect((screen.getByRole('button', { name: '上一页' }) as HTMLButtonElement).disabled).toBe(true);
    await user.click(screen.getByRole('button', { name: '下一页' }));
    expect(onPage).toHaveBeenCalledWith(2);

    // 页码钮直达 + 当前页 aria-current（设计稿 I）。
    await user.click(screen.getByRole('button', { name: '3' }));
    expect(onPage).toHaveBeenCalledWith(3);

    rerender(<Pager page={3} pageCount={3} onPage={onPage} />);
    expect((screen.getByRole('button', { name: '下一页' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByRole('button', { name: '3' }).getAttribute('aria-current')).toBe('page');
  });

  it('collapses long page lists with ellipses around the current page', () => {
    render(<Pager page={5} pageCount={9} onPage={() => {}} />);

    const texts = [...screen.getByRole('navigation').querySelectorAll('button, .gap')]
      .map((el) => el.textContent);
    expect(texts).toEqual(['‹', '1', '…', '4', '5', '6', '…', '9', '›']);
  });
});
