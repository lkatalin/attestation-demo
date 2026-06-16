import { useCallback, useEffect, useRef, useState } from "react";
import type { PodInfo } from "../types";
import {
  defaultGateControl,
  migratePathControls,
  type GateId,
} from "../lib/gatePaths";
import {
  buildDefaultPositions,
  clientToVirtual,
  loadSavedLayout,
  normalizePathControls,
  saveLayout,
  type Point,
} from "../lib/topologyCoords";

const DRAG_THRESHOLD = 6;

type DragKind = "node" | "path";

interface DragState {
  kind: DragKind;
  id: string;
  startClient: { x: number; y: number };
  moved: boolean;
}

export function useDraggableLayout(
  cvms: PodInfo[],
  workers: PodInfo[],
  showPendingCvm: boolean,
  layoutEpoch = 0
) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [positions, setPositions] = useState<Record<string, Point>>(() => {
    const saved = loadSavedLayout().positions;
    return saved ?? buildDefaultPositions(cvms, workers, showPendingCvm);
  });
  const [pathControls, setPathControls] = useState<Record<string, Point>>(() =>
    migratePathControls(
      normalizePathControls(loadSavedLayout().pathControls ?? {})
    )
  );
  const dragRef = useRef<DragState | null>(null);
  const skipClickRef = useRef(false);
  const [draggingPathId, setDraggingPathId] = useState<string | null>(null);

  useEffect(() => {
    if (layoutEpoch === 0) return;
    setPositions(buildDefaultPositions(cvms, workers, showPendingCvm));
    setPathControls({});
  }, [layoutEpoch, cvms, workers, showPendingCvm]);

  useEffect(() => {
    const defaults = buildDefaultPositions(cvms, workers, showPendingCvm);
    setPositions((prev) => {
      const next = { ...prev };
      let changed = false;
      for (const [id, pt] of Object.entries(defaults)) {
        if (!next[id]) {
          next[id] = pt;
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [cvms, workers, showPendingCvm]);

  useEffect(() => {
    saveLayout(positions, pathControls);
  }, [positions, pathControls]);

  const getControl = useCallback(
    (gateKey: string, from: Point, to: Point, gate: GateId): Point => {
      return pathControls[gateKey] ?? defaultGateControl(from, to, gate);
    },
    [pathControls]
  );

  const onNodePointerDown = useCallback(
    (id: string, e: React.PointerEvent) => {
      if (e.button !== 0) return;
      (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
      dragRef.current = {
        kind: "node",
        id,
        startClient: { x: e.clientX, y: e.clientY },
        moved: false,
      };
      skipClickRef.current = false;
    },
    []
  );

  const onPathPointerDown = useCallback(
    (gateKey: string, currentControl: Point, e: React.PointerEvent) => {
      if (e.button !== 0) return;
      e.stopPropagation();
      (e.currentTarget as SVGPathElement).setPointerCapture(e.pointerId);
      setPathControls((prev) =>
        prev[gateKey] ? prev : { ...prev, [gateKey]: currentControl }
      );
      dragRef.current = {
        kind: "path",
        id: gateKey,
        startClient: { x: e.clientX, y: e.clientY },
        moved: false,
      };
      setDraggingPathId(gateKey);
      skipClickRef.current = false;
    },
    []
  );

  const onPointerMove = useCallback((e: React.PointerEvent) => {
    const drag = dragRef.current;
    const container = containerRef.current;
    if (!drag || !container) return;

    const dx = e.clientX - drag.startClient.x;
    const dy = e.clientY - drag.startClient.y;
    if (!drag.moved && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;

    drag.moved = true;
    skipClickRef.current = true;
    const pt = clientToVirtual(container, e.clientX, e.clientY);

    if (drag.kind === "node") {
      setPositions((prev) => ({ ...prev, [drag.id]: pt }));
    } else {
      setPathControls((prev) => ({ ...prev, [drag.id]: pt }));
    }
  }, []);

  const onPointerUp = useCallback(() => {
    dragRef.current = null;
    setDraggingPathId(null);
  }, []);

  const shouldSkipClick = useCallback(() => {
    if (skipClickRef.current) {
      skipClickRef.current = false;
      return true;
    }
    return false;
  }, []);

  return {
    containerRef,
    positions,
    pathControls,
    getControl,
    onNodePointerDown,
    onPathPointerDown,
    onPointerMove,
    onPointerUp,
    shouldSkipClick,
    draggingPathId,
  };
}
