import { createRoot } from 'react-dom/client';
import './styles.css';

function App() {
  return (
    <main className="app-shell">
      <aside className="sidebar">
        <strong>TokenMeter</strong>
        <nav>
          <a>Dashboard</a>
          <a>Sessions</a>
          <a>Index Status</a>
          <a>Settings</a>
        </nav>
      </aside>
      <section className="content">
        <h1>本地 token 使用</h1>
        <p>连接 Swift 常驻层后显示 provider、agent、project 和 session 数据。</p>
      </section>
    </main>
  );
}

createRoot(document.getElementById('root')!).render(<App />);
