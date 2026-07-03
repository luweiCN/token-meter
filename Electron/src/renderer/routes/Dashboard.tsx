export function Dashboard() {
  return (
    <>
      <p className="eyebrow">Local analytics</p>
      <h1>Dashboard</h1>
      <p className="lede">Provider, agent, project, and model token usage will appear here once query repositories are connected.</p>
      <div className="placeholder-grid" aria-label="Dashboard preview cards">
        <article className="metric-card">
          <span>Total tokens</span>
          <strong>Waiting for data</strong>
        </article>
        <article className="metric-card">
          <span>Active agents</span>
          <strong>Indexed locally</strong>
        </article>
      </div>
    </>
  );
}
