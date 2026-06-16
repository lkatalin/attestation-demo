import type { CSSProperties } from "react";
import type { AttestationFlow, PodInfo } from "../types";

export const VB_W = 900;
export const VB_H = 520;

export type Point = { x: number; y: number };

export function posStyle(p: Point): CSSProperties {
  return { left: `${(p.x / VB_W) * 100}%`, top: `${(p.y / VB_H) * 100}%` };
}

export function clientToVirtual(
  container: HTMLElement,
  clientX: number,
  clientY: number
): Point {
  const rect = container.getBoundingClientRect();
  return {
    x: Math.max(40, Math.min(VB_W - 40, ((clientX - rect.left) / rect.width) * VB_W)),
    y: Math.max(40, Math.min(VB_H - 40, ((clientY - rect.top) / rect.height) * VB_H)),
  };
}

export function defaultControl(
  from: Point,
  to: Point,
  kind: string
): Point {
  const mx = (from.x + to.x) / 2;
  const bend = kind === "dek-policy" ? 40 : kind === "image-policy" ? -30 : 0;
  return { x: mx, y: from.y + bend };
}

export function curvePath(from: Point, control: Point, to: Point): string {
  return `M ${from.x} ${from.y} Q ${control.x} ${control.y} ${to.x} ${to.y}`;
}

/** Point on quadratic bezier at t (for label placement along curve). */
export function quadPoint(from: Point, control: Point, to: Point, t = 0.5): Point {
  const u = 1 - t;
  return {
    x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
    y: u * u * from.y + 2 * u * t * control.y + t * t * to.y,
  };
}

export function buildDefaultPositions(
  cvms: PodInfo[],
  workers: PodInfo[],
  showPendingCvm: boolean
): Record<string, Point> {
  const kbs: Point = { x: 720, y: 260 };
  const pendingCvm: Point = { x: 140, y: 260 };
  const positions: Record<string, Point> = { kbs };

  cvms.forEach((pod, i) => {
    positions[pod.name] = {
      x: 140,
      y:
        cvms.length === 1
          ? 260
          : 120 + i * (280 / Math.max(cvms.length - 1, 1)),
    };
  });

  workers.forEach((pod, i) => {
    positions[pod.name] = {
      x: 140 + (i % 2) * 200,
      y: 420 + Math.floor(i / 2) * 70,
    };
  });

  if (showPendingCvm) {
    positions["__pending_cvm__"] = pendingCvm;
  }

  return positions;
}

export function resolveFlowEndpoint(
  sourcePod: string | null | undefined,
  tee: string | null | undefined,
  positions: Record<string, Point>,
  cvms: PodInfo[],
  workers: PodInfo[],
  showPendingCvm: boolean
): Point {
  if (sourcePod && positions[sourcePod]) {
    return positions[sourcePod];
  }
  if (tee === "Sample") {
    const base = workers.find((p) => p.role === "baseline-encrypted-fail");
    if (base && positions[base.name]) return positions[base.name];
  }
  if (cvms.length) {
    const last = cvms[cvms.length - 1];
    if (positions[last.name]) return positions[last.name];
  }
  if (showPendingCvm && positions["__pending_cvm__"]) {
    return positions["__pending_cvm__"];
  }
  return { x: 140, y: 260 };
}

export function cvmGatePoints(
  cvm: Point,
  expanded: boolean
): { outer: Point; inner: Point; center: Point } {
  if (!expanded) {
    return { outer: cvm, inner: cvm, center: cvm };
  }
  return {
    outer: { x: cvm.x + 48, y: cvm.y - 14 },
    inner: { x: cvm.x + 34, y: cvm.y + 10 },
    center: cvm,
  };
}

export function kbsGatePoints(kbs: Point): { center: Point; image: Point; dek: Point } {
  return {
    center: kbs,
    image: { x: kbs.x - 42, y: kbs.y - 30 },
    dek: { x: kbs.x - 42, y: kbs.y + 30 },
  };
}

export function flowEndpoints(
  kind: string,
  fromBase: Point,
  toBase: Point,
  opts: { kbsExpanded: boolean; cvmExpanded: boolean }
): { from: Point; to: Point } {
  const kbsGates = kbsGatePoints(toBase);
  const cvmGates = cvmGatePoints(fromBase, opts.cvmExpanded);

  let to = toBase;
  if (opts.kbsExpanded) {
    if (
      kind === "image-policy" ||
      kind === "attest-image"
    ) {
      to = kbsGates.image;
    } else if (kind === "dek-policy" || kind === "attest-dek") {
      to = kbsGates.dek;
    } else {
      to = kbsGates.center;
    }
  }

  let from = fromBase;
  if (opts.cvmExpanded) {
    if (kind === "image-policy") {
      from = cvmGates.outer;
    } else if (kind === "attest-image") {
      from = {
        x: (cvmGates.center.x + cvmGates.outer.x) / 2,
        y: (cvmGates.center.y + cvmGates.outer.y) / 2,
      };
    } else if (kind === "dek-policy") {
      from = cvmGates.inner;
    } else if (kind === "attest-dek") {
      from = {
        x: (cvmGates.center.x + cvmGates.inner.x) / 2,
        y: (cvmGates.center.y + cvmGates.inner.y) / 2,
      };
    } else {
      from = cvmGates.center;
    }
  }

  return { from, to };
}

export function flowPathKey(sourcePod: string | null | undefined, kind: string): string {
  return `${sourcePod ?? "_unknown"}:${kind}`;
}

export function latestFlowsByPath(flows: AttestationFlow[]): AttestationFlow[] {
  const rank = (status: AttestationFlow["status"]) => {
    if (status === "pass") return 3;
    if (status === "verifying") return 2;
    if (status === "pending") return 1;
    return 0;
  };
  const map = new Map<string, AttestationFlow>();
  for (const flow of flows) {
    const key = flowPathKey(flow.sourcePod, flow.kind);
    const prev = map.get(key);
    if (
      !prev ||
      rank(flow.status) > rank(prev.status) ||
      (rank(flow.status) === rank(prev.status) && flow.timestamp > prev.timestamp)
    ) {
      map.set(key, flow);
    }
  }
  return Array.from(map.values());
}

export function normalizePathControls(
  controls: Record<string, Point>
): Record<string, Point> {
  const next: Record<string, Point> = {};
  for (const [key, point] of Object.entries(controls)) {
    if (key.includes(":")) next[key] = point;
  }
  return next;
}

const STORAGE_KEY = "demo-ui-topology-layout";

export function loadSavedLayout(): {
  positions?: Record<string, Point>;
  pathControls?: Record<string, Point>;
} {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

export function saveLayout(
  positions: Record<string, Point>,
  pathControls: Record<string, Point>
) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ positions, pathControls }));
  } catch {
    /* ignore quota */
  }
}

export function clearSavedLayout() {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
}
