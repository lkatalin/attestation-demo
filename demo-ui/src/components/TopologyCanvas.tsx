import { useMemo } from "react";
import type { CSSProperties } from "react";
import type { AttestationFlow, DemoState, PodInfo } from "../types";
import { useDraggableLayout } from "../hooks/useDraggableLayout";
import { buildGatePathGeometry } from "../lib/gatePaths";
import { pathGlowFilter, pathStrokeColor } from "../lib/demoColors";
import { normalizeFlowsForDisplay } from "../lib/flowNormalize";
import { posStyle } from "../lib/topologyCoords";

interface Props {
  state: DemoState | null;
  flowsByPod: Map<string, AttestationFlow[]>;
  onKbsClick: () => void;
  onPolicyInspect: (policy: "image" | "dek") => void;
  onKbsHover: (hovered: boolean) => void;
  onCvmClick: (pod: string) => void;
  onCvmHover: (podName: string | null) => void;
  onFlowClick: (flow: AttestationFlow) => void;
  onFlowHover: (flow: AttestationFlow | null) => void;
  selectedFlowId?: string;
  hoverFlow: AttestationFlow | null;
  hoveredCvm: string | null;
  kbsHovered: boolean;
  layoutEpoch?: number;
}

const ROLE_LABEL: Record<string, string> = {
  confidential: "CVM",
  "plaintext-control": "Plaintext",
  "baseline-encrypted-fail": "Baseline",
};

export function TopologyCanvas({
  state,
  flowsByPod,
  onKbsClick,
  onPolicyInspect,
  onKbsHover,
  onCvmClick,
  onCvmHover,
  onFlowClick,
  onFlowHover,
  selectedFlowId,
  hoverFlow,
  hoveredCvm,
  kbsHovered,
  layoutEpoch = 0,
}: Props) {
  const pods = state?.pods ?? [];
  const cvms = pods.filter((p) => p.role === "confidential");
  const others = pods.filter((p) => p.role !== "confidential");

  const activeFlows = useMemo(
    () => normalizeFlowsForDisplay(state?.flows ?? [], pods),
    [state?.flows, pods]
  );
  const showPendingCvm =
    cvms.length === 0 &&
    activeFlows.some(
      (f) =>
        f.tee === "AzSnpVtpm" ||
        f.kind === "image-policy" ||
        f.kind === "dek-policy"
    );

  const {
    containerRef,
    positions,
    getControl,
    onNodePointerDown,
    onPathPointerDown,
    onPointerMove,
    onPointerUp,
    shouldSkipClick,
    draggingPathId,
  } = useDraggableLayout(cvms, others, showPendingCvm, layoutEpoch);

  const kbsPos = positions.kbs ?? { x: 720, y: 260 };

  const flowGeometry = useMemo(() => {
    return activeFlows
      .map((flow) =>
        buildGatePathGeometry(flow, positions, kbsPos, cvms, others, showPendingCvm, {
          kbsExpanded: kbsHovered,
          hoveredCvm,
          getControl,
        })
      )
      .filter((geo): geo is NonNullable<typeof geo> => geo !== null);
  }, [
    activeFlows,
    positions,
    kbsPos,
    cvms,
    others,
    showPendingCvm,
    getControl,
    kbsHovered,
    hoveredCvm,
  ]);

  return (
    <div
      ref={containerRef}
      className={`topology ${draggingPathId ? "dragging-path" : ""}`}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerLeave={onPointerUp}
    >
      <svg className="paths" viewBox="0 0 900 520" preserveAspectRatio="xMidYMid meet">
        <defs>
          <filter id="glow-cyan">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
          <filter id="glow-magenta">
            <feGaussianBlur stdDeviation="4" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
          <filter id="glow-violet">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
          <filter id="glow-lime">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
          <filter id="glow-amber">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        {flowGeometry.map(({ flow, gateKey, control, labelPt, d }) => {
          const color = pathStrokeColor(flow);
          const selected = flow.id === selectedFlowId;
          const hovered = hoverFlow?.id === flow.id;
          const bundleActive =
            draggingPathId === gateKey || hovered || selected;
          const showLabel = bundleActive;
          const dragging = draggingPathId === gateKey;

          return (
            <g key={`${gateKey}:${flow.kind}`} className="flow-group">
              <path
                d={d}
                className={`flow-path-hit ${dragging ? "dragging" : ""}`}
                fill="none"
                stroke="transparent"
                strokeWidth={18}
                onPointerDown={(e) => onPathPointerDown(gateKey, control, e)}
                onClick={() => {
                  if (shouldSkipClick()) return;
                  onFlowClick(flow);
                }}
                onMouseEnter={() => onFlowHover(flow)}
                onMouseLeave={() => onFlowHover(null)}
              />
              <path
                d={d}
                className={`flow-path kind-${flow.kind} status-${flow.status} ${selected ? "selected" : ""} ${hovered ? "hovered" : ""} ${dragging ? "dragging" : ""}`}
                fill="none"
                stroke={color}
                strokeWidth={bundleActive ? 4 : 2.5}
                pointerEvents="none"
                filter={pathGlowFilter(flow)}
              />
              {showLabel && (
                <text
                  x={labelPt.x}
                  y={labelPt.y + (flow.kind.startsWith("attest-") ? -12 : 8)}
                  className="path-label"
                  textAnchor="middle"
                  pointerEvents="none"
                >
                  {friendlyPathLabel(flow)}
                </text>
              )}
              {dragging && flow.kind.endsWith("-policy") && (
                <circle
                  cx={control.x}
                  cy={control.y}
                  r={5}
                  className="path-control-dot"
                  pointerEvents="none"
                />
              )}
            </g>
          );
        })}
      </svg>

      <KbsNode
        style={posStyle(kbsPos)}
        expanded={kbsHovered}
        hasPolicies={Boolean(state?.kbs.resourcePolicy || state?.kbs.imagePolicy)}
        onPointerDown={onNodePointerDown}
        shouldSkipClick={shouldSkipClick}
        onActivate={onKbsClick}
        onHover={onKbsHover}
        onPolicyInspect={onPolicyInspect}
      />

      {showPendingCvm && positions["__pending_cvm__"] && (
        <DraggableNode
          id="__pending_cvm__"
          className="node cvm-node pending"
          style={posStyle(positions["__pending_cvm__"])}
          onPointerDown={onNodePointerDown}
          shouldSkipClick={shouldSkipClick}
        >
          <span className="node-icon">▣</span>
          <span className="node-title">CVM (booting)</span>
          <span className="node-sub">waiting for pod in cluster watch…</span>
        </DraggableNode>
      )}

      {cvms.map((pod) => (
        <PodNode
          key={pod.name}
          pod={pod}
          style={posStyle(positions[pod.name] ?? { x: 140, y: 260 })}
          expanded={hoveredCvm === pod.name}
          onPointerDown={onNodePointerDown}
          shouldSkipClick={shouldSkipClick}
          onClick={() => onCvmClick(pod.name)}
          flows={flowsByPod.get(pod.name) ?? []}
          onHover={onCvmHover}
        />
      ))}

      {others.map((pod) => {
        const flows = flowsByPod.get(pod.name) ?? [];
        const dekFlow = [...flows].reverse().find((f) => f.kind === "dek-policy");
        const last = dekFlow ?? flows[flows.length - 1];
        const crashing = !pod.ready && pod.restartCount > 0;
        return (
          <DraggableNode
            key={pod.name}
            id={pod.name}
            className={`node worker-node role-${pod.role} ${last?.status === "deny" ? "last-deny" : ""}`}
            style={posStyle(positions[pod.name] ?? { x: 140, y: 420 })}
            onPointerDown={onNodePointerDown}
            shouldSkipClick={shouldSkipClick}
            onActivate={() => {
              if (pod.role === "baseline-encrypted-fail" && last) onFlowClick(last);
            }}
          >
            <span className="node-title">{ROLE_LABEL[pod.role] ?? pod.role}</span>
            <span className="node-sub">{pod.name}</span>
            <span className={`ready ${pod.ready ? "yes" : "no"}`}>
              {pod.ready ? "Ready" : crashing ? "CrashLoopBackOff" : pod.phase}
            </span>
            {pod.role === "baseline-encrypted-fail" && (
              <span className="node-meta deny-label">
                {last?.status === "deny"
                  ? "DEK denied (sample attester)"
                  : "Sample attester — no DEK release"}
              </span>
            )}
          </DraggableNode>
        );
      })}
    </div>
  );
}

function KbsNode({
  style,
  expanded,
  hasPolicies,
  onPointerDown,
  shouldSkipClick,
  onActivate,
  onHover,
  onPolicyInspect,
}: {
  style: CSSProperties;
  expanded: boolean;
  hasPolicies: boolean;
  onPointerDown: (id: string, e: React.PointerEvent) => void;
  shouldSkipClick: () => boolean;
  onActivate: () => void;
  onHover: (hovered: boolean) => void;
  onPolicyInspect: (policy: "image" | "dek") => void;
}) {
  const stop = (e: React.PointerEvent | React.MouseEvent) => e.stopPropagation();

  return (
    <div
      role="button"
      tabIndex={0}
      className={`node kbs-node ${expanded ? "expanded" : ""}`}
      style={style}
      onPointerDown={(e) => onPointerDown("kbs", e)}
      onClick={() => {
        if (shouldSkipClick()) return;
        onActivate();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") onActivate();
      }}
      onMouseEnter={() => onHover(true)}
      onMouseLeave={() => onHover(false)}
    >
      <span className="node-icon">⬡</span>
      <span className="node-title">KBS / Trustee</span>
      {!expanded ? (
        <>
          <span className="node-sub">Key Broker Service</span>
          <span className="node-meta">
            {hasPolicies ? "Hover to see policy gates" : "Waiting for policies"}
          </span>
        </>
      ) : (
        <div className="kbs-gates">
          <button
            type="button"
            className="policy-gate image"
            onPointerDown={stop}
            onClick={(e) => {
              e.stopPropagation();
              onPolicyInspect("image");
            }}
          >
            <span className="gate-label">Image Pull Gate</span>
            <span className="gate-hint">Signed image may enter CVM</span>
          </button>
          <button
            type="button"
            className="policy-gate dek"
            onPointerDown={stop}
            onClick={(e) => {
              e.stopPropagation();
              onPolicyInspect("dek");
            }}
          >
            <span className="gate-label">DEK Release Gate</span>
            <span className="gate-hint">Approved guest may get key</span>
          </button>
        </div>
      )}
      <span className="drag-hint">drag to move</span>
    </div>
  );
}

function DraggableNode({
  id,
  className,
  style,
  children,
  onPointerDown,
  shouldSkipClick,
  onActivate,
}: {
  id: string;
  className: string;
  style: CSSProperties;
  children: React.ReactNode;
  onPointerDown: (id: string, e: React.PointerEvent) => void;
  shouldSkipClick: () => boolean;
  onActivate?: () => void;
}) {
  return (
    <div
      role="button"
      tabIndex={0}
      className={`${className} draggable`}
      style={style}
      onPointerDown={(e) => onPointerDown(id, e)}
      onClick={() => {
        if (shouldSkipClick()) return;
        onActivate?.();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") onActivate?.();
      }}
    >
      {children}
    </div>
  );
}

function PodNode({
  pod,
  style,
  expanded,
  onPointerDown,
  shouldSkipClick,
  onClick,
  flows,
  onHover,
}: {
  pod: PodInfo;
  style: CSSProperties;
  expanded: boolean;
  onPointerDown: (id: string, e: React.PointerEvent) => void;
  shouldSkipClick: () => boolean;
  onClick: () => void;
  flows: AttestationFlow[];
  onHover: (podName: string | null) => void;
}) {
  const last = flows[flows.length - 1];
  const status = last?.status;

  return (
    <div
      role="button"
      tabIndex={0}
      className={`node cvm-node draggable ${pod.isGolden ? "golden" : ""} ${status ? `last-${status}` : ""} ${expanded ? "expanded" : ""}`}
      style={style}
      onPointerDown={(e) => onPointerDown(pod.name, e)}
      onClick={() => {
        if (shouldSkipClick()) return;
        onClick();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") onClick();
      }}
      onMouseEnter={() => onHover(pod.name)}
      onMouseLeave={() => onHover(null)}
    >
      {!expanded ? (
        <>
          <span className="node-icon">▣</span>
          <span className="node-title">CVM {pod.isGolden ? "(golden)" : ""}</span>
          <span className="node-sub">{pod.name}</span>
          <span className="node-meta">{pod.runtimeClass || "kata-remote"}</span>
          <span className={`ready ${pod.ready ? "yes" : "no"}`}>
            {pod.ready ? "Ready · decrypt OK" : pod.phase}
          </span>
        </>
      ) : (
        <div className="vault-outer">
          <span className="vault-tag outer-tag">Image pull shell</span>
          <div className="vault-inner">
            <span className="vault-tag inner-tag">DEK vault core</span>
            <div className="vault-core">
              <span className="node-title">CVM {pod.isGolden ? "(golden)" : ""}</span>
              <span className="node-sub">{pod.name}</span>
              <span className={`ready ${pod.ready ? "yes" : "no"}`}>
                {pod.ready ? "Ready · decrypt OK" : pod.phase}
              </span>
            </div>
          </div>
        </div>
      )}
      <span className="drag-hint">drag to move</span>
    </div>
  );
}

function friendlyPathLabel(flow: AttestationFlow): string {
  if (flow.kind === "attest-image") {
    return flow.status === "pass"
      ? "Hardware attestation (image gate)"
      : "Hardware attestation failed";
  }
  if (flow.kind === "attest-dek") {
    return flow.status === "pass"
      ? "Hardware attestation (DEK gate)"
      : "Hardware attestation failed";
  }
  if (flow.kind === "image-policy") {
    return flow.status === "deny"
      ? "Image pull blocked by policy"
      : "Image pull policy passed";
  }
  return flow.status === "deny"
    ? "DEK release blocked by policy"
    : "DEK released to CVM";
}
