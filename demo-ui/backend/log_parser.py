"""Parse Trustee deployment logs into attestation flow events."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Literal

FlowKind = Literal["attest-image", "attest-dek", "image-policy", "dek-policy"]
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
    "attest-image": "hardware attest (image gate)",
    "attest-dek": "hardware attest (DEK gate)",
    "image-policy": "image policy (cosign pull)",
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
        for key in (
            f"{source_pod}:{kind}" if source_pod else None,
            f"{tee}:{kind}" if tee else None,
            f"_unknown:{kind}",
        ):
            if key and (flow := self._policy_slots.get(key)):
                return flow
        for flow in self._policy_slots.values():
            if flow.kind != kind:
                continue
            if source_pod and flow.source_pod == source_pod:
                return flow
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
        for key in (
            f"{source_pod}:{kind}" if source_pod else None,
            f"{tee}:{kind}" if tee else None,
            f"_unknown:{kind}",
        ):
            if key and (flow := self._attest_slots.get(key)):
                return flow
        for flow in self._attest_slots.values():
            if flow.kind != kind:
                continue
            if source_pod and flow.source_pod == source_pod:
                return flow
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
        if len(self.flows) > 80:
            self.flows = self.flows[-80:]
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

    def correlate_pod(self, tee: str, pods: list[dict]) -> str | None:
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
            booting = [p for p in conf if not p.get("ready")]
            if booting:
                return booting[-1].get("name")
            return conf[-1].get("name")
        return None

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

        if flow.kind == "dek-policy":
            if flow.status == "pass":
                if tee == "Sample":
                    return None
                return self.correlate_pod(tee or "AzSnpVtpm", pods)
            if flow.status == "deny":
                if tee == "AzSnpVtpm":
                    return self.correlate_pod("AzSnpVtpm", pods)
                if baseline:
                    flow.tee = tee or "Sample"
                    return baseline.get("name")
                return None

        if flow.kind in ("attest-image", "attest-dek", "attest"):
            if tee:
                return self.correlate_pod(tee, pods)
            if flow.status == "deny" and baseline:
                flow.tee = "Sample"
                return baseline.get("name")
            if flow.status == "pass":
                return self.correlate_pod("AzSnpVtpm", pods)

        if flow.kind == "image-policy":
            if flow.status == "pass":
                return self.correlate_pod(tee or "AzSnpVtpm", pods)
            if tee == "Sample" and baseline:
                return baseline.get("name")
            if flow.status == "deny" and baseline and tee != "AzSnpVtpm":
                flow.tee = tee or "Sample"
                return baseline.get("name")
            return self.correlate_pod(tee or "AzSnpVtpm", pods)

        if tee:
            return self.correlate_pod(tee, pods)
        return None

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
            gate: AttestGate = "image" if flow.kind == "image-policy" else "dek"
            attest = self._pair_attest_for_gate(gate, flow, flow.source_pod)
            if attest not in changed:
                changed.append(attest)

        changed.extend(self.reconcile_ready_pods(pods))
        return changed

    def backfill_pods(self, pods: list[dict]) -> list[AttestationFlow]:
        """Attach pod names to recent flows once pods appear in the watch."""
        return self.repair_attribution(pods)

    def reconcile_ready_pods(self, pods: list[dict]) -> list[AttestationFlow]:
        """Ready confidential pods pulled a signed image and received the DEK."""
        changed: list[AttestationFlow] = []
        for pod in pods:
            if pod.get("role") != "confidential" or not pod.get("ready"):
                continue
            name = pod.get("name")
            if not name:
                continue
            for gate in ("image", "dek"):
                changed.extend(self._ensure_gate_pass(name, gate, changed))
        return changed

    def _ensure_gate_pass(
        self, pod_name: str, gate: AttestGate, already: list[AttestationFlow]
    ) -> list[AttestationFlow]:
        changed: list[AttestationFlow] = []
        policy_kind: FlowKind = "image-policy" if gate == "image" else "dek-policy"
        policy = self._find_policy_flow(policy_kind, pod_name, "AzSnpVtpm")
        if policy is not None and policy.status == "deny":
            return changed
        if policy is None:
            policy = self._new_flow(
                policy_kind,
                "inferred from ready CVM"
                if gate == "dek"
                else "inferred image pull on ready CVM",
            )
            policy.tee = "AzSnpVtpm"
            policy.source_pod = pod_name
            policy.policy_name = (
                "trustee-image-policy"
                if gate == "image"
                else "resource Rego (DEK release)"
            )
            policy.status = "pass"
            policy.http_code = 200
            policy.deny_reason = None
            self._bind_policy_slot(policy)
            if policy not in already and policy not in changed:
                changed.append(policy)
        elif policy.status != "pass":
            policy.status = "pass"
            policy.http_code = policy.http_code or 200
            policy.deny_reason = None
            self._bind_policy_slot(policy)
            if policy not in already and policy not in changed:
                changed.append(policy)

        attest = self._pair_attest_for_gate(gate, policy, pod_name)
        if attest.status != "pass" and policy.status == "pass":
            attest.status = "pass"
            attest.deny_reason = None
        if attest not in already and attest not in changed:
            changed.append(attest)
        return changed
