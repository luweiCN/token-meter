import { useEffect, useRef, useState } from 'react';

/// 与 styles.css 「边栏 → 顶部栏」的 @media 断点保持同一数值。紧凑布局把 logo
/// 顶到左上角、原生红绿灯会压在上面，所以平时藏起按钮、悬停热区才显示；
/// 宽布局的边栏自带 .sidebar-drag 安置区，按钮常驻。
const COMPACT_LAYOUT_QUERY = '(max-width: 1100px)';

/// 指针滑进原生红绿灯（系统层）时 web 收不到事件、mouseleave 会先触发——
/// 延迟一拍再收，否则按钮会在指针底下消失又浮现。
const HIDE_DELAY_MS = 160;

function useCompactLayout(): boolean {
  const [compact, setCompact] = useState(() => window.matchMedia(COMPACT_LAYOUT_QUERY).matches);

  useEffect(() => {
    const mql = window.matchMedia(COMPACT_LAYOUT_QUERY);
    const onChange = (event: MediaQueryListEvent) => setCompact(event.matches);
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, []);

  return compact;
}

export function TrafficLightHover() {
  const compact = useCompactLayout();
  const [shown, setShown] = useState(false);
  const hideTimer = useRef<number | null>(null);

  const cancelScheduledHide = () => {
    if (hideTimer.current !== null) {
      window.clearTimeout(hideTimer.current);
      hideTimer.current = null;
    }
  };

  // 布局或悬停态一变就同步原生按钮：宽布局常驻可见，紧凑布局只在悬停时可见。
  useEffect(() => {
    void window.tokenMeter.windowControls.setButtonsVisible(compact ? shown : true);
  }, [compact, shown]);

  useEffect(() => {
    if (!compact) {
      setShown(false);
      return;
    }
    // 失焦（cmd-tab 走人）时收起，别让浮窗留在后台窗口上。
    const onBlur = () => setShown(false);
    window.addEventListener('blur', onBlur);
    return () => {
      window.removeEventListener('blur', onBlur);
      cancelScheduledHide();
    };
  }, [compact]);

  if (!compact) {
    return null;
  }

  return (
    <div
      className={shown ? 'traffic-hot shown' : 'traffic-hot'}
      aria-hidden="true"
      onMouseEnter={() => {
        cancelScheduledHide();
        setShown(true);
      }}
      onMouseLeave={() => {
        cancelScheduledHide();
        hideTimer.current = window.setTimeout(() => setShown(false), HIDE_DELAY_MS);
      }}
    />
  );
}
