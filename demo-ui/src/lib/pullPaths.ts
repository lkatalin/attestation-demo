import type { AttestationFlow } from "../types";
import { curvePath, quadPoint, type Point } from "./topologyCoords";

/** Bottom anchor on the registry node (paths terminate here). */
export function registryAnchor(registry: Point): Point {
  return { x: registry.x, y: registry.y + 30 };
}

export interface PullPathGeometry {
  flow: AttestationFlow;
  from: Point;
  to: Point;
  control: Point;
  d: string;
  labelPt: Point;
}

export function buildKubeletPullGeometry(
  flow: AttestationFlow,
  podPos: Point,
  registryPos: Point
): PullPathGeometry | null {
  if (!flow.sourcePod) return null;

  const from = { x: podPos.x + 28, y: podPos.y - 22 };
  const to = registryAnchor(registryPos);
  const control = {
    x: (from.x + to.x) / 2,
    y: Math.min(from.y, to.y) - 60,
  };

  return {
    flow,
    from,
    to,
    control,
    d: curvePath(from, control, to),
    labelPt: quadPoint(from, control, to, 0.42),
  };
}
