import { SessionTable } from '../components/SessionTable.js';

export function Sessions() {
  return (
    <>
      <p className="eyebrow">Session records</p>
      <h1>Sessions</h1>
      <p className="lede">Filter session usage by agent, project, model, and time without exposing prompts or assistant content.</p>
      <SessionTable />
    </>
  );
}
