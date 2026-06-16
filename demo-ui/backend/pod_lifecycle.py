"""Kubelet / registry image-pull flows driven by live pod status (not inferred)."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any, Literal

from .log_parser import AttestationFlow

FlowStatus = Literal["pending", "verifying", "pass", "deny"]

_STATUS_RANK = {"pending": 0, "verifying": 1, "pass": 3, "deny": 3}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


_REGISTRY_DENY_REASONS = frozenset(
    {"ImagePullBackOff", "ErrImagePull", "InvalidImageName"}
)


def _pull_status(pod: dict[str, Any]) -> FlowStatus:
    """Kubelet → registry only. DEK / guest boot failures are KBS paths, not pull deny."""
    reason = pod.get("containerWaitingReason") or ""
    if reason in _REGISTRY_DENY_REASONS:
        return "deny"
    if pod.get("containerStarted") or pod.get("imagePulled"):
        return "pass"
    # CreateContainerError on CVM/baseline = app or guest failed after pull (often DEK deny).
    if reason in ("CreateContainerError", "CrashLoopBackOff"):
        return "pass"
    phase = pod.get("phase") or ""
    if phase == "Pending":
        return "pending"
    if reason in ("ContainerCreating", "PodInitializing") or phase == "Running":
        return "verifying"
    return "pending"


def _should_apply_pull_status(current: FlowStatus, new: FlowStatus) -> bool:
    if current == new:
        return False
    if new == "pass" and current == "deny":
        return True
    return _STATUS_RANK.get(new, 0) >= _STATUS_RANK.get(current, 0)


def _pull_trigger(pod: dict[str, Any]) -> str:
    if pod.get("role") == "confidential":
        return "kubelet → registry (peer-pod outer image only)"
    return "kubelet → registry (workload image)"


class PodLifecycleTracker:
    """One kubelet-pull flow per pod, updated from the pod watch."""

    def __init__(self) -> None:
        self._pulls: dict[str, AttestationFlow] = {}

    def clear(self) -> None:
        self._pulls.clear()

    def flows(self) -> list[AttestationFlow]:
        return list(self._pulls.values())

    def remove_pod(self, name: str) -> None:
        self._pulls.pop(name, None)

    def sync_pod(self, pod: dict[str, Any]) -> list[AttestationFlow]:
        name = pod.get("name") or ""
        if not name:
            return []

        status = _pull_status(pod)
        reason = pod.get("containerWaitingReason") or ""
        changed: list[AttestationFlow] = []
        flow = self._pulls.get(name)

        if flow is None:
            flow = AttestationFlow(
                id=str(uuid.uuid4())[:8],
                kind="kubelet-pull",
                status="pending",
                source_pod=name,
                trigger=_pull_trigger(pod),
                timestamp=_now(),
            )
            self._pulls[name] = flow
            changed.append(flow)
        elif flow.trigger != _pull_trigger(pod):
            flow.trigger = _pull_trigger(pod)
            changed.append(flow)

        if _should_apply_pull_status(flow.status, status):
            flow.status = status
            flow.timestamp = _now()
            if status == "deny":
                flow.deny_reason = reason or "Registry image pull failed"
            else:
                flow.deny_reason = None
            changed.append(flow)

        return changed
