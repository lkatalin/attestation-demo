import type { AttestationFlow, FlowKind, PodInfo } from "../types";
import {
  curvePath,
  defaultControl,
  flowEndpoints,
  quadPoint,
  resolveFlowEndpoint,
  type Point,
} from "./topologyCoords";

export type GateId = "image" | "dek";

export function gateForKind(kind: FlowKind | string): GateId | null {
  switch (kind) {
    case "attest-image":
    case "image-policy":
      return "image";
    case "attest-dek":
    case "dek-policy":
    case "attest":
      return "dek";
    default:
      return null;
  }
}

export function isAttestKind(kind: FlowKind | string): boolean {
  return kind === "attest-image" || kind === "attest-dek" || kind === "attest";
}

export function gatePathKey(
  sourcePod: string | null | undefined,
  gate: GateId
): string {
  return `${sourcePod ?? "_unknown"}:${gate}-gate`;
}

/** Migrate saved drag handles from pre-gate path keys. */
export function migratePathControls(
  controls: Record<string, Point>
): Record<string, Point> {
  const next: Record<string, Point> = {};
  for (const [key, point] of Object.entries(controls)) {
    if (key.endsWith("-gate")) {
      next[key] = point;
      continue;
    }
    const colon = key.lastIndexOf(":");
    if (colon < 0) continue;
    const pod = key.slice(0, colon);
    const kind = key.slice(colon + 1);
    if (kind === "image-policy" || kind === "attest-image") {
      next[`${pod}:image-gate`] = point;
    } else if (kind === "dek-policy" || kind === "attest-dek" || kind === "attest") {
      next[`${pod}:dek-gate`] = point;
    }
  }
  return next;
}

function offsetVector(from: Point, to: Point, distance: number): Point {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const len = Math.hypot(dx, dy) || 1;
  return { x: (-dy / len) * distance, y: (dx / len) * distance };
}

export function laneOffset(kind: FlowKind): number {
  return isAttestKind(kind) ? -11 : 11;
}

export function applyLaneOffset(
  from: Point,
  to: Point,
  control: Point,
  kind: FlowKind
): { from: Point; to: Point; control: Point } {
  const o = offsetVector(from, to, laneOffset(kind));
  return {
    from: { x: from.x + o.x, y: from.y + o.y },
    to: { x: to.x + o.x, y: to.y + o.y },
    control: { x: control.x + o.x, y: control.y + o.y },
  };
}

export interface GatePathGeometry {
  flow: AttestationFlow;
  gate: GateId;
  gateKey: string;
  from: Point;
  to: Point;
  control: Point;
  d: string;
  labelPt: Point;
}

export function buildGatePathGeometry(
  flow: AttestationFlow,
  positions: Record<string, Point>,
  kbsPos: Point,
  cvms: PodInfo[],
  others: PodInfo[],
  showPendingCvm: boolean,
  opts: {
    kbsExpanded: boolean;
    hoveredCvm: string | null;
    getControl: (gateKey: string, from: Point, to: Point, gate: GateId) => Point;
  }
): GatePathGeometry | null {
  const gate = gateForKind(flow.kind);
  if (!gate || !flow.sourcePod) return null;

  const fromBase = resolveFlowEndpoint(
    flow.sourcePod,
    flow.tee,
    positions,
    cvms,
    others,
    showPendingCvm
  );
  const cvmExpanded = Boolean(flow.sourcePod && flow.sourcePod === opts.hoveredCvm);
  const { from: rawFrom, to: rawTo } = flowEndpoints(flow.kind, fromBase, kbsPos, {
    kbsExpanded: opts.kbsExpanded,
    cvmExpanded,
  });
  const gateKey = gatePathKey(flow.sourcePod, gate);
  const sharedControl = opts.getControl(gateKey, rawFrom, rawTo, gate);
  const { from, to, control } = applyLaneOffset(
    rawFrom,
    rawTo,
    sharedControl,
    flow.kind
  );
  return {
    flow,
    gate,
    gateKey,
    from,
    to,
    control,
    d: curvePath(from, control, to),
    labelPt: quadPoint(from, control, to, 0.5),
  };
}

export function defaultGateControl(
  from: Point,
  to: Point,
  gate: GateId
): Point {
  return defaultControl(from, to, gate === "dek" ? "dek-policy" : "image-policy");
}
