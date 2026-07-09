import { useState } from 'react';

import type { FailedFileSummary, IndexStatusResult, ScanRootSummary, ScanRunSummary } from '../api.js';

type IndexStatusState =
  | { kind: 'loading' }
  | { kind: 'loaded'; status: IndexStatusResult }
  | { kind: 'failed'; message: string };

interface IndexStatusProps {
  indexState: IndexStatusState;
  onRefresh(): Promise<void>;
}

export function IndexStatus({ indexState, onRefresh }: IndexStatusProps) {
  const [reindexing, setReindexing] = useState(false);
  const [reindexError, setReindexError] = useState<string | null>(null);

  async function handleReindex() {
    setReindexing(true);
    setReindexError(null);
    try {
      await window.tokenMeter.index.startFullReindex();
      await onRefresh();
    } catch (unknownError: unknown) {
      setReindexError(`重新索引失败：${unknownError instanceof Error ? unknownError.message : '未知错误'}`);
    } finally {
      setReindexing(false);
    }
  }

  return (
    <>
      <p className="eyebrow">本地索引</p>
      <div className="page-heading-row">
        <h1>索引状态</h1>
        <button className="primary-button" type="button" disabled={reindexing} onClick={handleReindex}>
          {reindexing ? '正在重新索引…' : '重新索引'}
        </button>
      </div>
      <p className="lede">查看 Swift 索引服务扫描的根目录、最近增量扫描和解析失败文件。</p>
      {indexState.kind === 'failed' ? <p className="status-error" role="status">索引状态加载失败：{indexState.message}</p> : null}
      {reindexError ? <p className="status-error" role="status">{reindexError}</p> : null}
      {indexState.kind === 'loading' ? <p className="muted" role="status">正在加载索引状态…</p> : null}
      {indexState.kind === 'loaded' ? <IndexStatusContent status={indexState.status} /> : null}
    </>
  );
}


function IndexStatusContent({ status }: { status: IndexStatusResult }) {
  return (
    <div className="status-grid">
      <section className="empty-panel" aria-label="扫描根目录">
        <h2>扫描根目录</h2>
        {status.roots.length === 0 ? <p className="muted">还没有启用的扫描根目录。</p> : status.roots.map((root) => <ScanRootCard key={root.id} root={root} />)}
      </section>

      <section className="empty-panel" aria-label="最近扫描">
        <h2>最近扫描</h2>
        {status.runs.length === 0 ? <p className="muted">还没有扫描记录。</p> : status.runs.map((run) => <ScanRunCard key={run.id} run={run} />)}
      </section>

      <section className="empty-panel" aria-label="失败文件">
        <h2>失败文件</h2>
        {status.failedFiles.length === 0 ? <p className="muted">当前没有解析失败文件。</p> : status.failedFiles.map((file) => <FailedFileRow key={file.id} file={file} />)}
      </section>
    </div>
  );
}

function ScanRootCard({ root }: { root: ScanRootSummary }) {
  return (
    <article className="status-card">
      <strong>{root.displayName}</strong>
      <dl>
        <dt>路径</dt>
        <dd>{root.rootPathLabel}</dd>
        <dt>类型</dt>
        <dd>{root.kind}</dd>
        <dt>状态</dt>
        <dd>{root.enabled ? '已启用' : '已停用'}</dd>
        <dt>上次完成</dt>
        <dd>{root.lastScanFinishedAt ?? '尚未完成'}</dd>
        {root.lastError ? <><dt>最近错误</dt><dd>{root.lastError}</dd></> : null}
      </dl>
    </article>
  );
}

function ScanRunCard({ run }: { run: ScanRunSummary }) {
  return (
    <article className="status-card">
      <strong>扫描 #{run.id} · {translateScanStatus(run.status)}</strong>
      <dl>
        <dt>开始时间</dt>
        <dd>{run.startedAt}</dd>
        <dt>完成时间</dt>
        <dd>{run.finishedAt ?? '进行中'}</dd>
        <dt>变更文件</dt>
        <dd>{run.filesChanged} / {run.filesSeen}</dd>
        <dt>新增用量行</dt>
        <dd>{run.usageRowsAdded}</dd>
        {run.errorSummary ? <><dt>错误摘要</dt><dd>{run.errorSummary}</dd></> : null}
      </dl>
    </article>
  );
}

function FailedFileRow({ file }: { file: FailedFileSummary }) {
  return (
    <article className="status-card">
      <strong>{file.relativePath}</strong>
      <dl>
        <dt>类型</dt>
        <dd>{file.fileType}</dd>
        <dt>更新时间</dt>
        <dd>{file.updatedAt}</dd>
        <dt>解析错误</dt>
        <dd>{file.parseError ?? '未知错误'}</dd>
      </dl>
    </article>
  );
}

function translateScanStatus(status: string) {
  switch (status) {
    case 'ok':
    case 'succeeded':
      return '成功';
    case 'partial':
      return '部分失败';
    case 'failed':
      return '失败';
    case 'running':
      return '运行中';
    default:
      return status;
  }
}
