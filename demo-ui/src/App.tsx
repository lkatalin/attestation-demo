import { useCallback, useEffect, useMemo, useState } from "react";
import type { AttestationFlow, DemoState } from "./types";
import { TopologyCanvas } from "./components/TopologyCanvas";
import { Modal } from "./components/Modal";
import { PromptPanel } from "./components/PromptPanel";
import { Timeline } from "./components/Timeline";
import { clearSavedLayout } from "./lib/topologyCoords";
import { flowsGroupedByPod } from "./lib/flowNormalize";

const ACT_LABELS: Record<string, string> = {
  prologue: "Prologue",
  i: "Act I — Staging",
  ii: "Act II — Production pins",
  iii: "Act III — Upgrade drill",
  unknown: "Watching…",
};

export default function App() {
  const [state, setState] = useState<DemoState | null>(null);
  const [wsStatus, setWsStatus] = useState<"connecting" | "open" | "error">("connecting");
  const [loadError, setLoadError] = useState<string | null>(null);
  const [modal, setModal] = useState<{
    title: string;
    body: React.ReactNode;
  } | null>(null);
  const [selectedFlow, setSelectedFlow] = useState<AttestationFlow | null>(null);
  const [hoverFlow, setHoverFlow] = useState<AttestationFlow | null>(null);
  const [kbsHovered, setKbsHovered] = useState(false);
  const [hoveredCvm, setHoveredCvm] = useState<string | null>(null);
  const [layoutEpoch, setLayoutEpoch] = useState(0);
  const [clearing, setClearing] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function bootstrap() {
      try {
        const res = await fetch("/api/state");
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        if (!cancelled) setState(data);
      } catch (err) {
        if (!cancelled) {
          setLoadError(
            err instanceof Error
              ? err.message
              : "Cannot reach demo UI backend — is python run.py running on port 8765?"
          );
        }
      }
    }

    bootstrap();

    const proto = window.location.protocol === "https:" ? "wss" : "ws";
    const ws = new WebSocket(`${proto}://${window.location.host}/ws`);

    ws.onopen = () => {
      setWsStatus("open");
      ws.send("refresh");
    };
    ws.onerror = () => setWsStatus("error");
    ws.onclose = () => setWsStatus("error");
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.type === "state") setState(msg.state);
      } catch {
        /* ignore malformed frames */
      }
    };

    return () => {
      cancelled = true;
      ws.close();
    };
  }, []);

  const loadPolicies = useCallback(async () => {
    let resourcePolicy = state?.kbs.resourcePolicy ?? "";
    let imagePolicy = state?.kbs.imagePolicy ?? "";
    let secrets = state?.kbs.secrets ?? [];
    try {
      const res = await fetch("/api/kbs/policies");
      if (res.ok) {
        const data = await res.json();
        resourcePolicy = data.resourcePolicy ?? resourcePolicy;
        imagePolicy = data.imagePolicy ?? imagePolicy;
        secrets = data.secrets ?? secrets;
      }
    } catch {
      /* use cached state */
    }
    return { resourcePolicy, imagePolicy, secrets };
  }, [state]);

  const showPolicyModal = useCallback(
    async (policy: "image" | "dek") => {
      const { resourcePolicy, imagePolicy, secrets } = await loadPolicies();
      const isImage = policy === "image";
      const title = isImage ? "Image Pull Policy" : "DEK Release Policy";
      const summary = isImage
        ? "Controls whether the CVM is allowed to pull and start the signed container image."
        : "Controls whether an already-attested CVM is allowed to receive the decryption key.";
      const code = isImage ? imagePolicy : resourcePolicy;
      setModal({
        title,
        body: (
          <div className="modal-stack">
            <p>{summary}</p>
            <p className="hint">
              Current status:{" "}
              {code ? "Policy is present in KBS and actively evaluated." : "Policy not found in KBS yet."}
            </p>
            <details>
              <summary>Show policy Rego / JSON</summary>
              <pre className="code-block">{code || "(empty policy body)"}</pre>
            </details>
            <details>
              <summary>Show registered KBS resources</summary>
              <ul className="secret-list">
                {(secrets.length ? secrets : ["(none registered)"]).map((s) => (
                  <li key={s}>{s}</li>
                ))}
              </ul>
            </details>
          </div>
        ),
      });
    },
    [loadPolicies]
  );

  const showKbs = useCallback(async () => {
    const { resourcePolicy, imagePolicy, secrets } = await loadPolicies();
    setModal({
      title: "KBS / Trustee — Policy Summary",
      body: (
        <div className="modal-stack">
          <section>
            <h3>High-level view</h3>
            <p>
              KBS evaluates two policy checks after hardware attestation: one for image pull, one for
              DEK key release.
            </p>
          </section>
          <section>
            <button type="button" className="mini-action" onClick={() => showPolicyModal("image")}>
              Inspect Image Pull Policy
            </button>
            <button type="button" className="mini-action" onClick={() => showPolicyModal("dek")}>
              Inspect DEK Release Policy
            </button>
          </section>
          <section>
            <h3>Policy presence</h3>
            <p>Image policy: {imagePolicy ? "loaded" : "missing"}</p>
            <p>DEK release policy: {resourcePolicy ? "loaded" : "missing"}</p>
            <p>KBS resources tracked: {secrets.length}</p>
          </section>
        </div>
      ),
    });
  }, [loadPolicies, showPolicyModal]);

  const showInitdata = useCallback(
    (podName: string) => {
      if (!state) return;
      setModal({
        title: `Initdata — cluster peer-pods config (${podName})`,
        body: (
          <div className="modal-stack">
            <p className="hint">
              Peer pods share one INITDATA in <code>peer-pods-cm</code>. New CVMs pick this up at
              boot; Act III mismatch appears when initdata or pins drift from golden.
            </p>
            <pre className="code-block">{state.initdata || "(not loaded)"}</pre>
          </div>
        ),
      });
    },
    [state]
  );

  const showFlow = useCallback((flow: AttestationFlow) => {
    setSelectedFlow(flow);
    setModal({
      title: `${flow.kind} — Summary`,
      body: (
        <div className="modal-stack">
          <div className="report-meta">
            <span className={`pill pill-${flow.status}`}>{flow.status}</span>
            {flow.tee && <span className="pill">tee={flow.tee}</span>}
            {flow.httpCode != null && <span className="pill">HTTP {flow.httpCode}</span>}
          </div>
          {flow.trigger && (
            <p>
              <strong>What triggered this:</strong> {flow.trigger}
            </p>
          )}
          {flow.policyName && (
            <p>
              <strong>Policy evaluated:</strong> {flow.policyName}
            </p>
          )}
          {flow.denyReason && flow.status === "deny" && (
            <p className="deny-box">
              <strong>Why it failed:</strong> {flow.denyReason}
            </p>
          )}
          <details>
            <summary>Show log-level details</summary>
            <pre className="code-block report">
              {(flow.reportLines.length ? flow.reportLines : ["(no lines captured yet)"]).join(
                "\n"
              )}
            </pre>
          </details>
        </div>
      ),
    });
  }, []);

  const actLabel = state
    ? ACT_LABELS[state.act] ?? state.act
    : loadError
      ? "Backend unreachable"
      : "Loading…";

  const flowsByPod = useMemo(() => {
    if (!state) return new Map<string, AttestationFlow[]>();
    return flowsGroupedByPod(state.flows, state.pods);
  }, [state]);

  const clearSession = useCallback(async () => {
    setClearing(true);
    try {
      const res = await fetch("/api/clear-session", { method: "POST" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      clearSavedLayout();
      setLayoutEpoch((n) => n + 1);
      setSelectedFlow(null);
      setHoverFlow(null);
      setHoveredCvm(null);
      setKbsHovered(false);
      setModal(null);
      if (data.state) setState(data.state);
    } catch (err) {
      setLoadError(err instanceof Error ? err.message : "Failed to clear session");
    } finally {
      setClearing(false);
    }
  }, []);

  return (
    <div className="app">
      <header className="topbar">
        <div>
          <h1>Confidential Inferencing</h1>
          <p className="subtitle">Live cluster topology — Acts I · II · III</p>
        </div>
        <div className="topbar-right">
          <button
            type="button"
            className="clear-session-btn"
            onClick={clearSession}
            disabled={clearing}
            title="Clear attestation paths, live feed, and dragged layout"
          >
            {clearing ? "Clearing…" : "Clear session"}
          </button>
          <span className={`act-badge act-${state?.act ?? "unknown"}`}>{actLabel}</span>
          <span className={`conn ${state?.connected ? "on" : "off"}`}>
            {state?.connected ? `● ${state.clusterUser}` : "○ not connected"}
          </span>
        </div>
      </header>

      {loadError && <div className="banner error">{loadError}</div>}
      {state?.error && <div className="banner error">{state.error}</div>}
      {wsStatus === "error" && state && (
        <div className="banner warn">
          Live WebSocket disconnected — showing last HTTP snapshot. Restart{" "}
          <code>python run.py</code> and refresh.
        </div>
      )}

      <main className="layout">
        <section className="canvas-wrap">
          <TopologyCanvas
            state={state}
            flowsByPod={flowsByPod}
            onKbsClick={showKbs}
            onPolicyInspect={showPolicyModal}
            onKbsHover={setKbsHovered}
            onCvmClick={showInitdata}
            onCvmHover={setHoveredCvm}
            onFlowClick={showFlow}
            onFlowHover={setHoverFlow}
            selectedFlowId={selectedFlow?.id}
            hoverFlow={hoverFlow}
            hoveredCvm={hoveredCvm}
            kbsHovered={kbsHovered}
            layoutEpoch={layoutEpoch}
          />
          <PromptPanel defaultPrompt={state?.defaultPrompt ?? ""} />
        </section>
        <aside className="sidebar">
          <Timeline entries={state?.timeline ?? []} />
        </aside>
      </main>

      {modal && (
        <Modal title={modal.title} onClose={() => setModal(null)}>
          {modal.body}
        </Modal>
      )}
    </div>
  );
}
