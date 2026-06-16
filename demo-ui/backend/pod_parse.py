"""Parse pod JSON into demo pod records."""

from __future__ import annotations

from typing import Any


def pod_from_k8s(item: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(item, dict):
        return {
            "name": "",
            "role": "unknown",
            "phase": "Unknown",
            "ready": False,
            "runtimeClass": "",
            "createdAt": "",
            "restartCount": 0,
            "imagePulled": False,
            "containerStarted": False,
            "containerWaitingReason": "",
        }
    meta = item.get("metadata") or {}
    if not isinstance(meta, dict):
        meta = {}
    status = item.get("status") or {}
    if not isinstance(status, dict):
        status = {}
    spec = item.get("spec") or {}
    if not isinstance(spec, dict):
        spec = {}
    labels = meta.get("labels") or {}
    if not isinstance(labels, dict):
        labels = {}
    cs = (status.get("containerStatuses") or [{}])[0]
    state = cs.get("state") or {}
    waiting = state.get("waiting") or {}
    return {
        "name": meta.get("name", ""),
        "role": labels.get("demo-role", "unknown"),
        "phase": status.get("phase", "Unknown"),
        "ready": bool(cs.get("ready")),
        "runtimeClass": spec.get("runtimeClassName") or "",
        "createdAt": meta.get("creationTimestamp", ""),
        "restartCount": cs.get("restartCount", 0),
        "imagePulled": bool(cs.get("imageID")),
        "containerStarted": bool(state.get("running")),
        "containerWaitingReason": waiting.get("reason") or "",
    }


def watch_event_pod(event: Any) -> tuple[str, dict[str, Any]]:
    """Normalize oc get -w output (WatchEvent, List item, or bare Pod)."""
    if isinstance(event, str):
        return "", {}
    if not isinstance(event, dict):
        return "", {}

    if event.get("kind") == "List":
        items = event.get("items") or []
        if isinstance(items, list) and items:
            first = items[0]
            if isinstance(first, dict) and first.get("kind") == "Pod":
                return "ADDED", first
        return "", {}

    if event.get("kind") == "Pod":
        meta = event.get("metadata")
        if isinstance(meta, dict):
            etype = event.get("type", "MODIFIED")
            return str(etype) if etype else "MODIFIED", event

    etype = str(event.get("type", "MODIFIED"))
    obj = event.get("object")
    if isinstance(obj, dict):
        return etype, obj
    return etype, {}
