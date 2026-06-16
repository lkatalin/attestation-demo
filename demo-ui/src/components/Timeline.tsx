import type { TimelineEntry } from "../types";

interface Props {
  entries: TimelineEntry[];
}

export function Timeline({ entries }: Props) {
  return (
    <div className="timeline">
      <h2>Live feed</h2>
      <p className="hint">Populated as the demo runs — not reconstructed from old logs.</p>
      <ul className="timeline-list">
        {[...entries].reverse().map((e, i) => (
          <li key={`${e.ts}-${i}`} className={`tl-${e.level}`}>
            <time>{new Date(e.ts).toLocaleTimeString()}</time>
            <span>{e.message}</span>
          </li>
        ))}
        {!entries.length && <li className="tl-empty">Waiting for cluster events…</li>}
      </ul>
    </div>
  );
}
