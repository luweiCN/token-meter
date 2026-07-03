export function IndexStatus() {
  return (
    <>
      <p className="eyebrow">Indexer state</p>
      <h1>Index Status</h1>
      <p className="lede">Review scan roots, incremental cursors, and failed files from the Swift indexing service.</p>
      <section className="empty-panel">
        <h2>No scan run selected</h2>
        <p>Task 14 will connect this panel to the SQLite index status repository.</p>
      </section>
    </>
  );
}
