import { SessionTable } from '../components/SessionTable.js';

export function Sessions() {
  return (
    <>
      <p className="eyebrow">会话记录</p>
      <h1>会话</h1>
      <p className="lede">按 Agent、项目、模型和时间筛选用量，不展示提示词、回复正文或工具输出。</p>
      <SessionTable />
    </>
  );
}
