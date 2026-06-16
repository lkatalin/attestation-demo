"""In-memory demo state built live from cluster watches."""

from __future__ import annotations

import re
import threading
from datetime import datetime, timezone
from typing import Any, Callable

from .log_parser import AttestationFlow, LogParser, RE_TEE_IN_LINE
from .pod_lifecycle import PodLifecycleTracker
from .pod_parse import pod_from_k8s, watch_event_pod
from . import oc_client

Listener = Callable[[dict[str, Any]], None]

PARSER_REV = "2025-06-16-golden-policy"


class DemoState:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._listeners: list[Listener] = []
        self.parser = LogParser()
        self.lifecycle = PodLifecycleTracker()
        self.connected = False
        self.cluster_user = ""
        self.error: str | None = None
        self.pods: list[dict[str, Any]] = []
        self.initdata = ""
        self.kbs: dict[str, Any] = {
            "endpoint": "",
            "resourcePolicy": "",
            "imagePolicy": "",
            "secrets": [],
        }
        self.act: str = "prologue"
        self.default_prompt = "encrypted model weights stay ciphertext until"
        self.timeline: list[dict[str, Any]] = []

    def subscribe(self, fn: Listener) -> None:
        self._listeners.append(fn)

    def _emit(self, event: dict[str, Any]) -> None:
        for fn in list(self._listeners):
            try:
                fn(event)
            except Exception:
                pass

    def _all_flow_dicts(self) -> list[dict[str, Any]]:
        merged = self.parser.flows_for_display(self.pods) + self.lifecycle.flows()
        return [f.to_dict() for f in merged]

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            if self.pods:
                active = {p["name"] for p in self.pods if p.get("name")}
                self.parser.prune_pods(active)
                for pod in self.pods:
                    self.lifecycle.sync_pod(pod)
                self.parser.repair_attribution(self.pods)
            golden = self._golden_pod_name()
            pods = []
            for p in self.pods:
                copy = dict(p)
                copy["isGolden"] = p.get("name") == golden
                pods.append(copy)
            return {
                "connected": self.connected,
                "clusterUser": self.cluster_user,
                "error": self.error,
                "act": self.act,
                "defaultPrompt": self.default_prompt,
                "kbs": dict(self.kbs),
                "initdata": self.initdata,
                "pods": pods,
                "flows": self._all_flow_dicts(),
                "timeline": list(self.timeline[-100:]),
                "parserRev": PARSER_REV,
            }

    def _golden_pod_name(self) -> str | None:
        conf = [p for p in self.pods if p.get("role") == "confidential"]
        if len(conf) <= 1:
            return conf[0]["name"] if conf else None
        return conf[0].get("name")

    def refresh_static(self) -> None:
        try:
            self.cluster_user = oc_client.whoami()
            self.connected = True
            self.error = None
        except RuntimeError as exc:
            self.connected = False
            self.error = str(exc)
            return

        try:
            self.pods = oc_client.get_pods()
            self._dedupe_pods()
            self.initdata = oc_client.get_initdata_toml()
            host = oc_client.get_confidential_route_host()
            self.kbs = {
                "endpoint": f"https://{host}" if host else "",
                "resourcePolicy": oc_client.get_resource_policy(),
                "imagePolicy": oc_client.get_image_policy(),
                "secrets": oc_client.get_kbs_secrets(),
            }
            self._detect_act()
            active = {p["name"] for p in self.pods if p.get("name")}
            self.parser.prune_pods(active)
            lifecycle_changed: list[AttestationFlow] = []
            for pod in self.pods:
                lifecycle_changed.extend(self.lifecycle.sync_pod(pod))
            self.parser.repair_attribution(self.pods)
            if self.parser.golden_missing_policy_passes(self.pods):
                tail = oc_client.fetch_trustee_tail(600)
                if tail:
                    self.parser.backfill_golden_from_trustee(tail, self.pods)
            for flow in lifecycle_changed:
                self.note_timeline(
                    self.parser.timeline_label(flow)
                    + (f" → {flow.source_pod}" if flow.source_pod else ""),
                    level="pass"
                    if flow.status == "pass"
                    else "deny"
                    if flow.status == "deny"
                    else "info",
                )
        except RuntimeError as exc:
            self.error = str(exc)

    def _detect_act(self) -> None:
        rego = self.kbs.get("resourcePolicy") or ""
        conf = [p for p in self.pods if p.get("role") == "confidential"]
        has_pins = bool(re.search(r"measurement", rego)) and bool(
            re.search(r"pcr11", rego)
        )
        stale = "act-iii" in rego.lower() or "stale" in rego.lower()

        if len(conf) >= 2:
            self.act = "iii"
        elif has_pins and not stale:
            self.act = "ii"
        elif rego.strip():
            self.act = "i"
        else:
            self.act = "prologue"

    def note_timeline(self, message: str, level: str = "info") -> None:
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": level,
            "message": message,
        }
        self.timeline.append(entry)
        self._emit({"type": "timeline", "entry": entry})

    def _dedupe_pods(self) -> None:
        by_name: dict[str, dict[str, Any]] = {}
        for pod in self.pods:
            name = pod.get("name")
            if name:
                by_name[name] = pod
        self.pods = sorted(by_name.values(), key=lambda p: p.get("createdAt", ""))

    def on_pod_watch(self, event: dict[str, Any]) -> None:
        etype, obj = watch_event_pod(event)
        if not obj:
            return
        meta = obj.get("metadata", {})
        name = meta.get("name", "")
        if not name:
            return
        if etype == "DELETED":
            self.pods = [p for p in self.pods if p.get("name") != name]
            self.lifecycle.remove_pod(name)
            self.parser.prune_pods({p["name"] for p in self.pods})
            self.note_timeline(f"Pod deleted: {name}")
        else:
            pod = pod_from_k8s(obj)
            found = False
            for i, p in enumerate(self.pods):
                if p.get("name") == name:
                    self.pods[i] = pod
                    found = True
                    break
            if not found:
                self.pods.append(pod)
            self._dedupe_pods()
            if etype == "ADDED":
                self.note_timeline(f"Pod added: {name} ({pod['role']})")
            self._detect_act()
            active = {p["name"] for p in self.pods if p.get("name")}
            self.parser.prune_pods(active)
            lifecycle_changed = self.lifecycle.sync_pod(pod)
            for flow in lifecycle_changed:
                self.note_timeline(
                    self.parser.timeline_label(flow)
                    + (f" → {flow.source_pod}" if flow.source_pod else ""),
                    level="pass"
                    if flow.status == "pass"
                    else "deny"
                    if flow.status == "deny"
                    else "info",
                )
            backfilled = self.parser.backfill_pods(self.pods)
            changed = list(lifecycle_changed) + list(backfilled)
            if changed:
                self._emit({"type": "flows", "flows": [f.to_dict() for f in changed]})
        self._emit({"type": "state", "state": self.snapshot()})

    def on_trustee_line(self, line: str) -> None:
        norm_line = self.parser._normalize_line(line)
        tee_hint = None
        if m := RE_TEE_IN_LINE.search(norm_line):
            tee_hint = m.group(1)
        elif "tee=AzSnpVtpm" in norm_line:
            tee_hint = "AzSnpVtpm"
        elif "tee=Sample" in norm_line:
            tee_hint = "Sample"

        pod_hint = None
        if tee_hint:
            pod_hint = self.parser.correlate_pod(tee_hint, self.pods)

        changed = self.parser.ingest(line, pod_hint=pod_hint)
        for flow in changed:
            if flow.source_pod is None and flow.tee:
                flow.source_pod = self.parser.correlate_pod(flow.tee, self.pods)
        repaired = self.parser.repair_attribution(self.pods)
        for flow in repaired:
            if flow not in changed:
                changed.append(flow)
        for flow in changed:
            self.note_timeline(
                self.parser.timeline_label(flow)
                + (f" (tee={flow.tee})" if flow.tee else "")
                + (f" → {flow.source_pod}" if flow.source_pod else ""),
                level="pass" if flow.status == "pass" else "deny" if flow.status == "deny" else "info",
            )
        if changed:
            self._emit({"type": "flows", "flows": [f.to_dict() for f in changed]})
            self._emit({"type": "state", "state": self.snapshot()})

    def apply_prompt_result(self, prompt: str, result: dict[str, Any]) -> None:
        self.note_timeline(f"Prompt sent: {prompt[:60]}…")
        self._emit({"type": "prompt_result", "prompt": prompt, "result": result})

    def clear_session(self) -> dict[str, Any]:
        """Reset live session artifacts; keep current cluster snapshot."""
        with self._lock:
            self.parser = LogParser()
            self.lifecycle = PodLifecycleTracker()
            self.timeline = []
            self.refresh_static()
            if self.parser.golden_missing_policy_passes(self.pods):
                tail = oc_client.fetch_trustee_tail(800)
                if tail:
                    self.parser.backfill_golden_from_trustee(tail, self.pods)
        snap = self.snapshot()
        self._emit({"type": "state", "state": snap})
        return snap
