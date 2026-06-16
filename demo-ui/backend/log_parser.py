"""Parse Trustee deployment logs into attestation flow events."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Literal

FlowKind = Literal[
    "kubelet-pull", "attest-image", "attest-dek", "image-policy", "dek-policy"
]
FlowStatus = Literal["pending", "verifying", "pass", "deny"]
AttestGate = Literal["image", "dek"]

RE_ATTEST = re.compile(r'POST /kbs/v0/attest HTTP/1\.1" (\d+)')
RE_VERIFIER = re.compile(r"Verifier/endorsement check passed\. tee=(\S+)")
RE_RESOURCE = re.compile(
    r'GET (?:/kbs/v0/)?(?:resource/)?([^"\s]*(?:trustee-image-policy|confidential-inferencing-dek)[^"\s]*) HTTP/1\.1" (\d+)'
)
RE_TEE_IN_LINE = re.compile(r"tee=(AzSnpVtpm|Sample)\b")
RE_POLICY_DENY = re.compile(r"PolicyDeny")
RE_IMAGE_POLICY = re.compile(r"trustee-image-policy")
RE_DEK = re.compile(r"confidential-inferencing-dek")
RE_SIGSTORE = re.compile(r"sigstore|image policy|Image policy rejected", re.I)

FLOW_LABELS = {
    "kubelet-pull": "kubelet image pull (registry)",
    "attest-image": "hardware attest (image gate)",
    "attest-dek": "hardware attest (DEK gate)",
    "image-policy": "CDH signed image pull (KBS policy)",
    "dek-policy": "DEK policy (resource Rego)",
}

RE_ANSI = re.compile(r"\x1b\[[0-9;]*m")


@dataclass
class AttestationFlow:
    id: str
    kind: FlowKind
    status: FlowStatus
    tee: str | None = None
    source_pod: str | None = None
    trigger: str | None = None
    http_code: int | None = None
    policy_name: str | None = None
    report_lines: list[str] = field(default_factory=list)
    deny_reason: str | None = None
    timestamp: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "kind": self.kind,
            "status": self.status,
            "tee": self.tee,
            "sourcePod": self.source_pod,
            "trigger": self.trigger,
            "httpCode": self.http_code,
            "policyName": self.policy_name,
            "reportLines": self.report_lines,
            "denyReason": self.deny_reason,
            "timestamp": self.timestamp,
        }


class LogParser:
    """Stateful parser correlating trustee lines into attestation flows."""

    def __init__(self) -> None:
        self.flows: list[AttestationFlow] = []
        self._open_attest: AttestationFlow | None = None
        self._recent_context: list[str] = []
        self._context_max = 12
        self._hw_context: dict[str, str | None] = {"tee": None, "source_pod": None}
        self._policy_slots: dict[str, AttestationFlow] = {}
        self._attest_slots: dict[str, AttestationFlow] = {}

    @staticmethod
    def _attest_kind(gate: AttestGate) -> FlowKind:
        return "attest-image" if gate == "image" else "attest-dek"

    def _now(self) -> str:
        return datetime.now(timezone.utc).isoformat()

    @staticmethod
    def _normalize_line(line: str) -> str:
        """Trustee uses structured logging with ANSI color codes around field names."""
        return RE_ANSI.sub("", line)

    def _push_context(self, line: str) -> None:
        self._recent_context.append(line)
        if len(self._recent_context) > self._context_max:
            self._recent_context.pop(0)

    def _remember_hw(
        self, tee: str | None = None, source_pod: str | None = None
    ) -> None:
        if tee:
            self._hw_context["tee"] = tee
        if source_pod:
            self._hw_context["source_pod"] = source_pod

    def _policy_slot_key(
        self, kind: FlowKind, source_pod: str | None, tee: str | None
    ) -> str:
        anchor = source_pod or tee or "_unknown"
        return f"{anchor}:{kind}"

    def _find_policy_flow(
        self, kind: FlowKind, source_pod: str | None, tee: str | None
    ) -> AttestationFlow | None:
        if source_pod:
            key = f"{source_pod}:{kind}"
            if flow := self._policy_slots.get(key):
                return flow
            for flow in self._policy_slots.values():
                if flow.kind == kind and flow.source_pod == source_pod:
                    return flow
            return None
        for key in (
            f"{tee}:{kind}" if tee else None,
            f"_unknown:{kind}",
        ):
            if key and (flow := self._policy_slots.get(key)):
                return flow
        for flow in self._policy_slots.values():
            if flow.kind != kind:
                continue
            if tee and flow.tee == tee:
                return flow
        return None

    def _bind_policy_slot(self, flow: AttestationFlow) -> None:
        key = self._policy_slot_key(flow.kind, flow.source_pod, flow.tee)
        for old_key, existing in list(self._policy_slots.items()):
            if existing is flow and old_key != key:
                del self._policy_slots[old_key]
        self._policy_slots[key] = flow

    def _find_attest_flow(
        self, kind: FlowKind, source_pod: str | None, tee: str | None
    ) -> AttestationFlow | None:
        if source_pod:
            key = f"{source_pod}:{kind}"
            if flow := self._attest_slots.get(key):
                return flow
            for flow in self._attest_slots.values():
                if flow.kind == kind and flow.source_pod == source_pod:
                    return flow
            return None
        for key in (
            f"{tee}:{kind}" if tee else None,
            f"_unknown:{kind}",
        ):
            if key and (flow := self._attest_slots.get(key)):
                return flow
        for flow in self._attest_slots.values():
            if flow.kind != kind:
                continue
            if tee and flow.tee == tee:
                return flow
        return None

    def _bind_attest_slot(self, flow: AttestationFlow) -> None:
        key = self._policy_slot_key(flow.kind, flow.source_pod, flow.tee)
        for old_key, existing in list(self._attest_slots.items()):
            if existing is flow and old_key != key:
                del self._attest_slots[old_key]
        self._attest_slots[key] = flow

    def _pair_attest_for_gate(
        self,
        gate: AttestGate,
        policy_flow: AttestationFlow,
        pod_hint: str | None,
    ) -> AttestationFlow:
        """CVM only — workers use kubelet pull, not hardware attest paths."""
        if policy_flow.tee == "Sample":
            att = self._find_attest_flow(
                self._attest_kind(gate), policy_flow.source_pod, "Sample"
            )
            if att is None:
                att = self._new_flow(
                    self._attest_kind(gate), "sample token (not shown on worker)"
                )
                att.tee = "Sample"
            att.source_pod = None
            return att

        attest_kind = self._attest_kind(gate)

        if self._open_attest:
            att = self._open_attest
            att.kind = attest_kind
            if policy_flow.tee:
                att.tee = policy_flow.tee
            if policy_flow.source_pod:
                att.source_pod = policy_flow.source_pod
            elif pod_hint:
                att.source_pod = pod_hint
            if att.status != "deny":
                att.status = "pass"
            self._bind_attest_slot(att)
            self._open_attest = None
            return att

        att = self._find_attest_flow(
            attest_kind, policy_flow.source_pod, policy_flow.tee
        )
        if att is None:
            att = self._new_flow(attest_kind, f"paired with {policy_flow.kind}")
        att.tee = policy_flow.tee or att.tee
        att.source_pod = policy_flow.source_pod or att.source_pod
        if policy_flow.status == "pass":
            if att.status != "deny":
                att.status = "pass"
                att.deny_reason = None
        elif policy_flow.status == "deny" and att.status != "deny":
            if att.status != "pass":
                att.status = "pass"
        att.timestamp = self._now()
        self._bind_attest_slot(att)
        return att

    def _attribute_resource(
        self, pod_hint: str | None
    ) -> tuple[str | None, str | None]:
        source_pod = pod_hint
        tee: str | None = None
        if self._open_attest:
            tee = self._open_attest.tee
            if not source_pod:
                source_pod = self._open_attest.source_pod
        if not tee:
            tee = self._hw_context.get("tee")
        if not source_pod:
            source_pod = self._hw_context.get("source_pod")
        return source_pod, tee

    def _new_flow(self, kind: FlowKind, trigger: str) -> AttestationFlow:
        flow = AttestationFlow(
            id=str(uuid.uuid4())[:8],
            kind=kind,
            status="pending",
            trigger=trigger,
            report_lines=list(self._recent_context),
            timestamp=self._now(),
        )
        self.flows.append(flow)
        if len(self.flows) > 160:
            self.flows = self.flows[-160:]
        return flow

    def _upsert_policy_flow(
        self, kind: FlowKind, trigger: str, pod_hint: str | None
    ) -> AttestationFlow:
        source_pod, tee = self._attribute_resource(pod_hint)
        flow = self._find_policy_flow(kind, source_pod, tee)
        if flow is None:
            flow = self._new_flow(kind, trigger)
        else:
            flow.timestamp = self._now()
        if tee:
            flow.tee = tee
        if source_pod:
            flow.source_pod = source_pod
        self._remember_hw(tee=flow.tee, source_pod=flow.source_pod)
        self._bind_policy_slot(flow)
        return flow

    def _apply_resource_status(
        self, flow: AttestationFlow, code: int, line: str, kind: FlowKind
    ) -> None:
        if flow.status == "pass" and code != 200:
            return
        flow.http_code = code
        if code == 200:
            flow.status = "pass"
            flow.deny_reason = None
            return
        if RE_POLICY_DENY.search(line) or code == 401:
            flow.status = "deny"
            flow.deny_reason = self._deny_reason(line, kind)
        else:
            flow.status = "deny"
            flow.deny_reason = f"HTTP {code}"

    def ingest(self, line: str, pod_hint: str | None = None) -> list[AttestationFlow]:
        """Parse one log line; return flows that changed."""
        line = self._normalize_line(line)
        self._push_context(line)
        changed: list[AttestationFlow] = []

        if m := RE_ATTEST.search(line):
            code = int(m.group(1))
            if self._open_attest and self._open_attest.kind in (
                "attest-dek",
                "attest-image",
                "attest",
            ):
                flow = self._open_attest
            else:
                flow = self._new_flow("attest-dek", "POST /kbs/v0/attest")
            flow.trigger = "POST /kbs/v0/attest"
            flow.http_code = code
            flow.status = "pass" if code == 200 else "deny"
            if code != 200:
                flow.deny_reason = f"KBS rejected attestation token (HTTP {code})"
            flow.report_lines.append(line)
            if not flow.tee:
                flow.tee = self._hw_context.get("tee")
            if pod_hint:
                flow.source_pod = pod_hint
            elif not flow.source_pod:
                flow.source_pod = self._hw_context.get("source_pod")
            self._open_attest = flow
            self._remember_hw(tee=flow.tee, source_pod=flow.source_pod)
            self._bind_attest_slot(flow)
            changed.append(flow)
            return changed

        if m := RE_VERIFIER.search(line):
            tee = m.group(1)
            flow = self._open_attest or self._new_flow(
                "attest-dek", "hardware verify"
            )
            flow.tee = tee
            if flow.status != "deny":
                flow.status = "pass"
            flow.report_lines.append(line)
            if pod_hint:
                flow.source_pod = pod_hint
            if not self._open_attest:
                self._open_attest = flow
            self._remember_hw(tee=tee, source_pod=flow.source_pod)
            changed.append(flow)

        if m := RE_RESOURCE.search(line):
            path, code_s = m.group(1), m.group(2)
            code = int(code_s)
            if RE_IMAGE_POLICY.search(path):
                kind = "image-policy"
                policy = "trustee-image-policy"
                trigger = "signed image pull (CDH boot)"
                gate: AttestGate = "image"
            elif RE_DEK.search(path):
                kind = "dek-policy"
                policy = "resource Rego (DEK release)"
                trigger = "runtime DEK fetch (CDH REST)"
                gate = "dek"
            else:
                return changed

            source_pod, tee = self._attribute_resource(pod_hint)
            if code != 200 and not source_pod and not tee:
                return changed

            flow = self._upsert_policy_flow(kind, trigger, pod_hint)
            flow.policy_name = policy
            flow.report_lines.append(line)
            if tee:
                flow.tee = tee
            elif not flow.tee:
                flow.tee = self._hw_context.get("tee")
            if pod_hint and not flow.source_pod:
                flow.source_pod = pod_hint
            elif source_pod and not flow.source_pod:
                flow.source_pod = source_pod
            self._apply_resource_status(flow, code, line, kind)

            if RE_SIGSTORE.search(line) and flow.status == "deny":
                flow.deny_reason = (flow.deny_reason or "") + " — image policy / sigstore"

            attest = self._pair_attest_for_gate(gate, flow, pod_hint)
            if flow not in changed:
                changed.append(flow)
            if attest not in changed:
                changed.append(attest)
            return changed

        if RE_POLICY_DENY.search(line) and not RE_RESOURCE.search(line):
            kind_hint: FlowKind | None = None
            if RE_DEK.search(line):
                kind_hint = "dek-policy"
            elif RE_IMAGE_POLICY.search(line):
                kind_hint = "image-policy"

            tee = self._hw_context.get("tee")
            source_pod = self._hw_context.get("source_pod")

            flow = None
            if kind_hint:
                flow = self._find_policy_flow(kind_hint, source_pod, tee)
            if flow is None:
                for candidate in reversed(self.flows):
                    if candidate.kind not in ("image-policy", "dek-policy"):
                        continue
                    if kind_hint and candidate.kind != kind_hint:
                        continue
                    if candidate.status == "pass" or candidate.http_code == 200:
                        continue
                    if tee and candidate.tee and candidate.tee != tee:
                        continue
                    flow = candidate
                    break

            if flow and flow.status != "pass" and flow.http_code != 200:
                flow.status = "deny"
                flow.deny_reason = self._deny_reason(line, flow.kind)
                flow.report_lines.append(line)
                if flow not in changed:
                    changed.append(flow)
                gate: AttestGate = (
                    "image" if flow.kind == "image-policy" else "dek"
                )
                attest = self._pair_attest_for_gate(
                    gate, flow, flow.source_pod
                )
                if attest not in changed:
                    changed.append(attest)

        return changed

    @staticmethod
    def timeline_label(flow: AttestationFlow) -> str:
        base = FLOW_LABELS.get(flow.kind, flow.kind)
        if flow.kind == "kubelet-pull":
            if flow.status == "pass":
                return f"{base}: image on worker node"
            if flow.status == "verifying":
                return f"{base}: pulling from registry…"
            if flow.status == "deny":
                return f"{base}: failed"
            return f"{base}: scheduled"
        if flow.kind in ("attest-image", "attest-dek") and flow.status == "pass":
            return f"{base}: pass (evidence OK)"
        if flow.kind == "dek-policy" and flow.status == "pass":
            return f"{base}: pass (DEK released)"
        return f"{base}: {flow.status}"

    @staticmethod
    def _deny_reason(line: str, kind: FlowKind) -> str:
        if "PluginInternal" in line:
            return "Policy evaluation failed (PluginInternal)"
        if kind == "image-policy":
            return "Image policy denied — cosign verification failed or policy mismatch"
        if kind == "dek-policy":
            return (
                "Resource Rego denied DEK — wrong tee claim, missing az-snp-vtpm, "
                "or measurement/pcr11 pin mismatch (Act II/III)"
            )
        return "PolicyDeny from Trustee"

    def correlate_pod(
        self, tee: str, pods: list[dict], *, prefer_ready: bool = False
    ) -> str | None:
        """Best-effort pod attribution from tee type and boot order."""
        if tee == "Sample":
            for p in pods:
                if p.get("role") == "baseline-encrypted-fail":
                    return p.get("name")
        if tee == "AzSnpVtpm":
            conf = sorted(
                [p for p in pods if p.get("role") == "confidential"],
                key=lambda p: p.get("createdAt", ""),
            )
            if not conf:
                return None
            if prefer_ready:
                ready = [p for p in conf if p.get("ready")]
                if ready:
                    return ready[0].get("name")
            booting = [p for p in conf if not p.get("ready")]
            if booting:
                return booting[-1].get("name")
            return conf[-1].get("name")
        return None

    def prune_attest_duplicates(self) -> None:
        """Keep the latest attest-* flow per pod so the cap does not drop policy paths."""
        best: dict[str, AttestationFlow] = {}
        for flow in self.flows:
            if flow.kind not in ("attest-image", "attest-dek", "attest"):
                continue
            key = f"{flow.source_pod or '_'}:{flow.kind}"
            prev = best.get(key)
            if not prev or flow.timestamp > prev.timestamp:
                best[key] = flow
        keep = {f.id for f in best.values()}
        self.flows = [
            f
            for f in self.flows
            if f.kind not in ("attest-image", "attest-dek", "attest") or f.id in keep
        ]

    def stabilize_golden_ready(self, pods: list[dict]) -> list[AttestationFlow]:
        """Ready golden CVM must have passed image + DEK gates at boot."""
        golden = self._golden_confidential_name(pods)
        if not golden:
            return []
        pod = next((p for p in pods if p.get("name") == golden), None)
        if not pod or not pod.get("ready") or not pod.get("containerStarted"):
            return []

        changed: list[AttestationFlow] = []
        for gate in ("image", "dek"):
            policy_kind: FlowKind = (
                "image-policy" if gate == "image" else "dek-policy"
            )
            attest_kind = self._attest_kind(gate)

            policy = self._find_policy_flow(policy_kind, golden, "AzSnpVtpm")
            if policy is None:
                policy = self._new_flow(
                    policy_kind,
                    "CVM running (image + DEK gates passed at boot)",
                )
                changed.append(policy)
            if policy.status != "pass" or policy.source_pod != golden:
                policy.status = "pass"
                policy.http_code = 200
                policy.source_pod = golden
                policy.tee = "AzSnpVtpm"
                policy.deny_reason = None
                self._bind_policy_slot(policy)
                if policy not in changed:
                    changed.append(policy)

            attest = self._find_attest_flow(attest_kind, golden, "AzSnpVtpm")
            if attest is None:
                attest = self._new_flow(
                    attest_kind, f"paired with {policy_kind} (golden CVM ready)"
                )
                changed.append(attest)
            if attest.status != "pass" or attest.source_pod != golden:
                attest.status = "pass"
                attest.source_pod = golden
                attest.tee = "AzSnpVtpm"
                attest.deny_reason = None
                self._bind_attest_slot(attest)
                if attest not in changed:
                    changed.append(attest)
        return changed

    @staticmethod
    def _latest_per_path(flows: list[AttestationFlow]) -> list[AttestationFlow]:
        rank = {"pass": 3, "verifying": 2, "pending": 1, "deny": 0}
        best: dict[str, AttestationFlow] = {}
        for flow in flows:
            key = f"{flow.source_pod or '_'}:{flow.kind}"
            prev = best.get(key)
            if not prev:
                best[key] = flow
                continue
            fr, pr = rank.get(flow.status, 0), rank.get(prev.status, 0)
            if fr > pr or (fr == pr and flow.timestamp > prev.timestamp):
                best[key] = flow
        return list(best.values())

    def _golden_confidential_name(self, pods: list[dict]) -> str | None:
        conf = sorted(
            [p for p in pods if p.get("role") == "confidential"],
            key=lambda p: p.get("createdAt", ""),
        )
        return conf[0].get("name") if conf else None

    def golden_missing_policy_passes(self, pods: list[dict]) -> bool:
        """True when the golden ready CVM lacks image or DEK policy pass flows."""
        golden = self._golden_confidential_name(pods)
        if not golden:
            return False
        golden_pod = next((p for p in pods if p.get("name") == golden), None)
        if not golden_pod or not golden_pod.get("ready"):
            return False
        has_image = any(
            f.kind == "image-policy"
            and f.status == "pass"
            and f.source_pod == golden
            for f in self.flows
        )
        has_dek = any(
            f.kind == "dek-policy"
            and f.status == "pass"
            and f.source_pod == golden
            for f in self.flows
        )
        return not has_image or not has_dek

    def prune_sample_noise(self, keep: int = 12) -> None:
        """Drop excess baseline Sample deny flows so CVM passes are not truncated."""
        sample_denies = [
            f
            for f in self.flows
            if f.tee == "Sample"
            and f.kind == "dek-policy"
            and f.status == "deny"
        ]
        if len(sample_denies) <= keep:
            return
        drop_ids = {f.id for f in sample_denies[:-keep]}
        self.flows = [f for f in self.flows if f.id not in drop_ids]

    def backfill_golden_from_trustee(
        self, lines: list[str], pods: list[dict]
    ) -> list[AttestationFlow]:
        """Replay trustee tail lines to recover golden CVM image/DEK policy passes."""
        golden = self._golden_confidential_name(pods)
        if not golden:
            return []
        golden_pod = next((p for p in pods if p.get("name") == golden), None)
        if not golden_pod or not golden_pod.get("ready"):
            return []
        if not self.golden_missing_policy_passes(pods):
            return []

        self.prune_sample_noise()
        changed: list[AttestationFlow] = []
        baseline = self._baseline_pod(pods)
        baseline_name = baseline.get("name") if baseline else None

        for line in lines:
            norm = self._normalize_line(line)
            is_resource = bool(RE_RESOURCE.search(norm))
            is_hw = bool(RE_VERIFIER.search(norm) or RE_ATTEST.search(norm))
            if not is_resource and not is_hw:
                continue

            pod_hint: str | None = None
            if "tee=Sample" in norm or (
                RE_VERIFIER.search(norm) and RE_VERIFIER.search(norm).group(1) == "Sample"
            ):
                pod_hint = baseline_name
            elif "AzSnpVtpm" in norm:
                pod_hint = golden
            elif is_resource and "confidential-inferencing-dek" in norm:
                if RE_RESOURCE.search(norm) and int(RE_RESOURCE.search(norm).group(2)) == 200:
                    pod_hint = golden
            elif is_resource and "trustee-image-policy" in norm:
                if RE_RESOURCE.search(norm) and int(RE_RESOURCE.search(norm).group(2)) == 200:
                    pod_hint = golden

            batch = self.ingest(line, pod_hint=pod_hint)
            for flow in batch:
                if flow not in changed:
                    changed.append(flow)

        repaired = self.repair_attribution(pods)
        for flow in repaired:
            if flow not in changed:
                changed.append(flow)
        return changed

    def _tee_from_report(self, flow: AttestationFlow) -> str | None:
        """Prefer the latest tee in the flow window (Trustee tail mixes workloads)."""
        tee: str | None = None
        for line in flow.report_lines:
            norm = self._normalize_line(line)
            if m := RE_VERIFIER.search(norm):
                tee = m.group(1)
            elif m := RE_TEE_IN_LINE.search(norm):
                tee = m.group(1)
        return tee

    def _baseline_pod(self, pods: list[dict]) -> dict | None:
        return next(
            (p for p in pods if p.get("role") == "baseline-encrypted-fail"), None
        )

    def _pod_for_flow(self, flow: AttestationFlow, pods: list[dict]) -> str | None:
        """Strict demo attribution: baseline never receives a DEK pass."""
        baseline = self._baseline_pod(pods)
        tee = flow.tee or self._tee_from_report(flow)
        prefer_ready = flow.status == "pass"

        if flow.kind == "dek-policy":
            if flow.status == "pass":
                if tee == "Sample":
                    return None
                return self.correlate_pod(
                    tee or "AzSnpVtpm", pods, prefer_ready=prefer_ready
                )
            if flow.status == "deny":
                if tee == "AzSnpVtpm":
                    return self.correlate_pod("AzSnpVtpm", pods, prefer_ready=False)
                if baseline:
                    flow.tee = tee or "Sample"
                    return baseline.get("name")
                return None

        if flow.kind in ("attest-image", "attest-dek", "attest"):
            if tee == "Sample":
                return None
            if tee:
                return self.correlate_pod(tee, pods, prefer_ready=prefer_ready)
            if flow.status == "pass":
                return self.correlate_pod("AzSnpVtpm", pods, prefer_ready=True)
            return None

        if flow.kind == "image-policy":
            if tee == "Sample" or (baseline and flow.status == "deny" and tee != "AzSnpVtpm"):
                return None
            if flow.status == "pass":
                return self.correlate_pod(
                    tee or "AzSnpVtpm", pods, prefer_ready=True
                )
            return self.correlate_pod(tee or "AzSnpVtpm", pods, prefer_ready=False)

        if tee:
            return self.correlate_pod(tee, pods, prefer_ready=prefer_ready)
        return None

    def _worker_pod_names(self, pods: list[dict]) -> set[str]:
        return {
            p["name"]
            for p in pods
            if p.get("role") != "confidential" and p.get("name")
        }

    def flows_for_display(self, pods: list[dict]) -> list[AttestationFlow]:
        """Hide hardware-attest paths on non-CVM workers (baseline/plaintext)."""
        workers = self._worker_pod_names(pods)
        baseline = self._baseline_pod(pods)
        baseline_name = baseline.get("name") if baseline else None
        visible: list[AttestationFlow] = []
        for flow in self.flows:
            if flow.kind in ("attest-image", "attest-dek", "attest"):
                if flow.tee == "Sample" or flow.source_pod in workers:
                    continue
            if flow.source_pod in workers:
                if flow.kind == "kubelet-pull":
                    visible.append(flow)
                elif (
                    flow.kind == "dek-policy"
                    and flow.status == "deny"
                    and flow.source_pod == baseline_name
                ):
                    visible.append(flow)
                continue
            visible.append(flow)
        return self._latest_per_path(visible)

    def pin_golden_pass_flows(self, pods: list[dict]) -> list[AttestationFlow]:
        """Re-home succeeded policy passes onto the golden ready CVM (not attest paths)."""
        golden = self._golden_confidential_name(pods)
        if not golden:
            return []
        golden_pod = next((p for p in pods if p.get("name") == golden), None)
        if not golden_pod or not golden_pod.get("ready"):
            return []

        changed: list[AttestationFlow] = []
        for flow in self.flows:
            if flow.kind not in ("image-policy", "dek-policy"):
                continue
            if flow.status != "pass":
                continue
            tee = flow.tee or self._tee_from_report(flow)
            if tee != "AzSnpVtpm":
                continue
            if flow.source_pod != golden:
                flow.source_pod = golden
                flow.tee = "AzSnpVtpm"
                self._bind_policy_slot(flow)
                changed.append(flow)
        return changed

    def _sync_attest_to_policy(self, pods: list[dict]) -> list[AttestationFlow]:
        """Keep attest-* on the same pod as its paired policy gate flow."""
        changed: list[AttestationFlow] = []
        conf_names = [
            p["name"] for p in pods if p.get("role") == "confidential" and p.get("name")
        ]
        for name in conf_names:
            for gate in ("image", "dek"):
                policy_kind: FlowKind = (
                    "image-policy" if gate == "image" else "dek-policy"
                )
                attest_kind = self._attest_kind(gate)
                policy = next(
                    (
                        f
                        for f in self.flows
                        if f.kind == policy_kind and f.source_pod == name
                    ),
                    None,
                )
                if not policy or policy.tee == "Sample":
                    continue
                attest = self._find_attest_flow(attest_kind, name, policy.tee)
                if attest is None:
                    attest = self._find_attest_flow(attest_kind, None, policy.tee)
                if attest is None:
                    attest = self._pair_attest_for_gate(gate, policy, name)
                if attest.source_pod != name:
                    attest.source_pod = name
                    attest.tee = policy.tee or "AzSnpVtpm"
                    self._bind_attest_slot(attest)
                    changed.append(attest)
        return changed

    def _confidential_pod(
        self, pods: list[dict], *, prefer_booting: bool = True
    ) -> str | None:
        conf = sorted(
            [p for p in pods if p.get("role") == "confidential"],
            key=lambda p: p.get("createdAt", ""),
        )
        if not conf:
            return None
        if prefer_booting:
            booting = [p for p in conf if not p.get("ready")]
            if booting:
                return booting[-1].get("name")
        ready = [p for p in conf if p.get("ready")]
        if len(ready) == 1:
            return ready[0].get("name")
        return conf[-1].get("name")

    def _assign_orphan_flows(self, pods: list[dict]) -> list[AttestationFlow]:
        """Attach pod names when tee is missing (stale sessions, ANSI parse gaps)."""
        changed: list[AttestationFlow] = []

        for flow in self.flows:
            if flow.source_pod:
                continue
            if not flow.tee:
                flow.tee = self._tee_from_report(flow)
            name = self._pod_for_flow(flow, pods)
            if name:
                flow.source_pod = name
                if flow.kind in ("image-policy", "dek-policy"):
                    self._bind_policy_slot(flow)
                elif flow.kind in ("attest-image", "attest-dek", "attest"):
                    self._bind_attest_slot(flow)
                if flow not in changed:
                    changed.append(flow)
        return changed

    def repair_attribution(self, pods: list[dict]) -> list[AttestationFlow]:
        """Backfill tee/pod on flows parsed before ANSI normalization or without hints."""
        changed: list[AttestationFlow] = []

        for flow in self.flows:
            if flow.kind == "attest":
                flow.kind = "attest-dek"
                changed.append(flow)

        for flow in self.flows:
            if not flow.tee:
                if tee := self._tee_from_report(flow):
                    flow.tee = tee
                    if flow not in changed:
                        changed.append(flow)

        for flow in self.flows:
            if flow.source_pod or not flow.tee:
                continue
            name = self._pod_for_flow(flow, pods)
            if name:
                flow.source_pod = name
                if flow.kind in ("image-policy", "dek-policy"):
                    self._bind_policy_slot(flow)
                elif flow.kind in ("attest-image", "attest-dek"):
                    self._bind_attest_slot(flow)
                if flow not in changed:
                    changed.append(flow)

        changed.extend(self._assign_orphan_flows(pods))

        for flow in self.flows:
            if flow.kind not in ("image-policy", "dek-policy") or not flow.source_pod:
                continue
            if flow.source_pod in self._worker_pod_names(pods):
                continue
            gate: AttestGate = "image" if flow.kind == "image-policy" else "dek"
            attest = self._pair_attest_for_gate(gate, flow, flow.source_pod)
            if attest not in changed:
                changed.append(attest)

        changed.extend(self.pin_golden_pass_flows(pods))
        changed.extend(self._sync_attest_to_policy(pods))
        self.prune_attest_duplicates()
        changed.extend(self.stabilize_golden_ready(pods))
        return changed

    def reset_cvm_attestation_flows(self) -> None:
        """Drop CVM/KBS flows when a new confidential pod rolls out (keep baseline Sample)."""
        self.flows = [f for f in self.flows if f.tee == "Sample"]
        self._open_attest = None
        self._policy_slots.clear()
        self._attest_slots.clear()
        self._hw_context = {"tee": None, "source_pod": None}

    def prune_pods(self, active_names: set[str]) -> None:
        """Drop flows for deleted pods so rollouts do not leave stale pass paths."""
        self.flows = [
            f
            for f in self.flows
            if not f.source_pod or f.source_pod in active_names
        ]
        for key in list(self._policy_slots.keys()):
            pod = key.split(":", 1)[0]
            if pod not in active_names and pod != "_unknown":
                del self._policy_slots[key]
        for key in list(self._attest_slots.keys()):
            pod = key.split(":", 1)[0]
            if pod not in active_names and pod != "_unknown":
                del self._attest_slots[key]

    def backfill_pods(self, pods: list[dict]) -> list[AttestationFlow]:
        """Attach pod names to recent flows once pods appear in the watch."""
        return self.repair_attribution(pods)
