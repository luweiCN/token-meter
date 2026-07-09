export function SessionTable() {
  return (
    <section className="table-placeholder" aria-label="会话用量表占位">
      <div className="table-row table-header">
        <span>Agent</span>
        <span>项目</span>
        <span>模型</span>
        <span>Token</span>
      </div>
      <p>会话明细将从本地 SQLite 查询结果加载。</p>
    </section>
  );
}
