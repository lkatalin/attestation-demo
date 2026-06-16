import type { AttestationFlow, FlowKind, PodInfo } from "../types";
import { isAttestKind } from "./gatePaths";
import { latestFlowsByPath } from "./topologyCoords";

const RE_TEE = /tee=(AzSnpVtpm|Sample)\b/;
const RE_VERIFIER = /Verifier\/endorsement check passed\. tee=(\S+)/;
const RE_RESOURCE =
  /GET (?:\/kbs\/v0\/)?(?:resource\/)?([^"\s]*(?:trustee-image-policy|confidential-inferencing-dek)[^"\s]*) HTTP\/1\.1" (\d+)/;
const RE_IMAGE_POLICY = /trustee-image-policy/;
const RE_DEK = /confidential-inferencing-dek/;

function stripAnsi(line: string): string {
  return line.replace(/\x1b\[[0-9;]*m/g, "");
}

/** Prefer the latest tee — Trustee tail mixes baseline Sample and CVM AzSnpVtpm lines. */
export function teeFromReport(lines: string[]): string | undefined {
  let tee: string | undefined;
  for (const raw of lines) {
    const line = stripAnsi(raw);
    const verifier = line.match(RE_VERIFIER);
    if (verifier) tee = verifier[1];
    else {
      const inline = line.match(RE_TEE);
      if (inline) tee = inline[1];
    }
  }
  return tee;
}

function goldenConfidentialPod(pods: PodInfo[]): PodInfo | undefined {
  const conf = pods
    .filter((p) => p.role === "confidential")
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  return conf[0];
}

export function correlatePod(
  tee: string | null | undefined,
  pods: PodInfo[],
  opts?: { preferReady?: boolean }
): string | undefined {
  if (!tee) return undefined;
  if (tee === "Sample") {
    return pods.find((p) => p.role === "baseline-encrypted-fail")?.name;
  }
  if (tee === "AzSnpVtpm") {
    const conf = pods
      .filter((p) => p.role === "confidential")
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    if (opts?.preferReady) {
      const ready = conf.filter((p) => p.ready);
      if (ready.length) return ready[0].name;
    }
    const booting = conf.filter((p) => !p.ready);
    if (booting.length) return booting[booting.length - 1].name;
    return conf[conf.length - 1]?.name;
  }
  return undefined;
}

function migrateKind(kind: string): FlowKind {
  if (kind === "attest") return "attest-dek";
  return kind as FlowKind;
}

/** Strict demo attribution: baseline never receives a DEK pass. */
export function podForFlow(flow: AttestationFlow, pods: PodInfo[]): string | undefined {
  if (flow.kind === "kubelet-pull") return flow.sourcePod ?? undefined;

  const baseline = pods.find((p) => p.role === "baseline-encrypted-fail");
  const tee = flow.tee ?? teeFromReport(flow.reportLines);
  const preferReady = flow.status === "pass";

  if (flow.kind === "dek-policy") {
    if (flow.status === "pass") {
      if (tee === "Sample") return undefined;
      return correlatePod(tee ?? "AzSnpVtpm", pods, { preferReady: true });
    }
    if (flow.status === "deny") {
      if (tee === "AzSnpVtpm") return correlatePod("AzSnpVtpm", pods);
      return baseline?.name;
    }
  }

  const kind = flow.kind as string;
  if (
    kind === "attest-dek" ||
    kind === "attest-image" ||
    kind === "attest"
  ) {
    if (tee === "Sample") return undefined;
    if (tee) return correlatePod(tee, pods, { preferReady });
    if (flow.status === "pass") {
      return correlatePod("AzSnpVtpm", pods, { preferReady: true });
    }
    return undefined;
  }

  if (flow.kind === "image-policy") {
    if (tee === "Sample") return undefined;
    if (flow.status === "pass") {
      return correlatePod(tee ?? "AzSnpVtpm", pods, { preferReady: true });
    }
    return correlatePod(tee ?? "AzSnpVtpm", pods);
  }

  if (tee) return correlatePod(tee, pods, { preferReady });
  return undefined;
}

function flowVisibleOnPod(flow: AttestationFlow, pods: PodInfo[]): boolean {
  if (!flow.sourcePod) {
    return flow.kind === "dek-policy" || flow.kind === "image-policy";
  }
  const pod = pods.find((p) => p.name === flow.sourcePod);
  if (!pod || pod.role === "confidential") return true;
  if (flow.kind === "kubelet-pull") return true;
  if (
    flow.kind === "dek-policy" &&
    flow.status === "deny" &&
    pod.role === "baseline-encrypted-fail"
  ) {
    return true;
  }
  return false;
}

function pinGoldenPolicyPasses(working: AttestationFlow[], pods: PodInfo[]): void {
  const golden = goldenConfidentialPod(pods);
  if (!golden?.ready) return;

  for (const f of working) {
    if (f.kind !== "image-policy" && f.kind !== "dek-policy") continue;
    if (f.status !== "pass") continue;
    const tee = f.tee ?? teeFromReport(f.reportLines);
    if (tee !== "AzSnpVtpm") continue;
    f.sourcePod = golden.name;
    f.tee = "AzSnpVtpm";
  }
}

function syncAttestToPolicyPods(working: AttestationFlow[], pods: PodInfo[]): void {
  const confNames = pods
    .filter((p) => p.role === "confidential")
    .map((p) => p.name);

  for (const podName of confNames) {
    for (const gate of ["image", "dek"] as const) {
      const policyKind: FlowKind = gate === "image" ? "image-policy" : "dek-policy";
      const attestKind: FlowKind = gate === "image" ? "attest-image" : "attest-dek";
      const policy = working.find(
        (f) => f.kind === policyKind && f.sourcePod === podName
      );
      if (!policy || policy.tee === "Sample") continue;

      let attest = working.find(
        (f) =>
          f.kind === attestKind &&
          (f.sourcePod === podName || f.tee === policy.tee)
      );
      if (!attest) {
        const ts = new Date().toISOString();
        attest = {
          id: `sync-${podName}-${attestKind}`,
          kind: attestKind,
          status: policy.status === "deny" ? "pass" : policy.status,
          sourcePod: podName,
          tee: policy.tee ?? "AzSnpVtpm",
          reportLines: [],
          timestamp: ts,
        };
        working.push(attest);
      }
      attest.sourcePod = podName;
      attest.tee = policy.tee ?? "AzSnpVtpm";
      if (isAttestKind(attest.kind) && policy.status === "deny" && attest.status !== "deny") {
        attest.status = "pass";
      }
    }
  }
}

function pinGoldenPassFlows(working: AttestationFlow[], pods: PodInfo[]): void {
  pinGoldenPolicyPasses(working, pods);
}

/** Recover policy GET lines bundled inside attest report windows (stale sessions). */
function policyFlowsFromReportLines(
  flows: AttestationFlow[],
  pods: PodInfo[]
): AttestationFlow[] {
  const rank = (status: AttestationFlow["status"]) =>
    status === "pass" ? 2 : status === "deny" ? 1 : 0;
  const best = new Map<string, AttestationFlow>();

  for (const parent of flows) {
    let tee = parent.tee ?? teeFromReport(parent.reportLines);
    for (const raw of parent.reportLines) {
      const line = stripAnsi(raw);
      const verifier = line.match(RE_VERIFIER);
      if (verifier) tee = verifier[1];
      const inline = line.match(RE_TEE);
      if (inline) tee = inline[1];

      const m = line.match(RE_RESOURCE);
      if (!m) continue;
      const path = m[1];
      const code = parseInt(m[2], 10);
      let kind: FlowKind | null = null;
      if (RE_IMAGE_POLICY.test(path)) kind = "image-policy";
      else if (RE_DEK.test(path)) kind = "dek-policy";
      if (!kind) continue;

      const status: AttestationFlow["status"] = code === 200 ? "pass" : "deny";
      const draft: AttestationFlow = {
        id: `report-${kind}-${code}`,
        kind,
        status,
        tee: tee ?? undefined,
        httpCode: code,
        reportLines: [line],
        timestamp: parent.timestamp,
      };
      const sourcePod = podForFlow(draft, pods);
      if (!sourcePod) continue;
      draft.sourcePod = sourcePod;

      const key = `${sourcePod}:${kind}`;
      const prev = best.get(key);
      if (!prev || rank(status) > rank(prev.status)) {
        best.set(key, draft);
      }
    }
  }
  return Array.from(best.values());
}

function stabilizeGoldenReady(working: AttestationFlow[], pods: PodInfo[]): void {
  const golden = goldenConfidentialPod(pods);
  if (!golden?.ready) return;
  if (golden.containerStarted === false) return;

  for (const gate of ["image", "dek"] as const) {
    const policyKind: FlowKind = gate === "image" ? "image-policy" : "dek-policy";
    const attestKind: FlowKind = gate === "image" ? "attest-image" : "attest-dek";
    let policy = working.find(
      (f) => f.kind === policyKind && f.sourcePod === golden.name
    );
    if (!policy || policy.status !== "pass") {
      if (!policy) {
        policy = {
          id: `stable-${golden.name}-${policyKind}`,
          kind: policyKind,
          status: "pass",
          sourcePod: golden.name,
          tee: "AzSnpVtpm",
          httpCode: 200,
          reportLines: [],
          timestamp: new Date().toISOString(),
        };
        working.push(policy);
      } else {
        policy.status = "pass";
        policy.httpCode = 200;
        policy.tee = "AzSnpVtpm";
      }
    }

    let attest = working.find(
      (f) => f.kind === attestKind && f.sourcePod === golden.name
    );
    if (!attest || attest.status !== "pass") {
      if (!attest) {
        attest = {
          id: `stable-${golden.name}-${attestKind}`,
          kind: attestKind,
          status: "pass",
          sourcePod: golden.name,
          tee: "AzSnpVtpm",
          reportLines: [],
          timestamp: policy.timestamp,
        };
        working.push(attest);
      } else {
        attest.status = "pass";
        attest.tee = "AzSnpVtpm";
      }
    }
  }
}

function reconcileKubeletPull(working: AttestationFlow[], pods: PodInfo[]): void {
  for (const pod of pods) {
    const pull = working.find(
      (f) => f.kind === "kubelet-pull" && f.sourcePod === pod.name
    );
    if (!pull) continue;

    const guestFailed = ["CreateContainerError", "CrashLoopBackOff"].includes(
      pod.containerWaitingReason ?? ""
    );
    const dekDeny = working.some(
      (f) =>
        f.kind === "dek-policy" &&
        f.sourcePod === pod.name &&
        f.status === "deny"
    );
    const attestPass = working.some(
      (f) =>
        (f.kind === "attest-dek" || f.kind === "attest-image") &&
        f.sourcePod === pod.name &&
        f.status === "pass"
    );

    // CVM attested but DEK denied — outer image was on the worker; not a registry fail.
    if (pull.status === "deny" && (guestFailed || (pod.role === "confidential" && dekDeny && attestPass))) {
      pull.status = "pass";
      pull.denyReason = undefined;
    }
  }
}

export function normalizeFlowsForDisplay(
  flows: AttestationFlow[],
  pods: PodInfo[]
): AttestationFlow[] {
  if (!flows.length && !pods.length) return [];

  const working: AttestationFlow[] = flows.map((f) => {
    const tee = f.tee ?? teeFromReport(f.reportLines) ?? undefined;
    const kind = migrateKind(f.kind as string);
    const normalized = { ...f, kind, tee };
    return {
      ...normalized,
      sourcePod: f.sourcePod ?? podForFlow(normalized, pods) ?? undefined,
    };
  });

  for (const extra of policyFlowsFromReportLines(flows, pods)) {
    const existing = working.find(
      (f) => f.kind === extra.kind && f.sourcePod === extra.sourcePod
    );
    if (!existing || (extra.status === "pass" && existing.status !== "pass")) {
      if (existing && extra.status === "pass") {
        Object.assign(existing, extra);
      } else if (!existing) {
        working.push(extra);
      }
    }
  }

  const baseline = pods.find((p) => p.role === "baseline-encrypted-fail");

  for (const f of working) {
    if (f.sourcePod) continue;
    const pod = podForFlow(f, pods);
    if (pod) f.sourcePod = pod;
  }

  for (const f of working) {
    if (
      f.kind === "dek-policy" &&
      f.status === "pass" &&
      baseline &&
      f.sourcePod === baseline.name
    ) {
      f.sourcePod = correlatePod("AzSnpVtpm", pods, { preferReady: true });
      f.tee = "AzSnpVtpm";
    }
  }

  pinGoldenPassFlows(working, pods);
  syncAttestToPolicyPods(working, pods);
  stabilizeGoldenReady(working, pods);
  reconcileKubeletPull(working, pods);

  const latest = latestFlowsByPath(working);
  const kindsWithPod = new Set(
    latest.filter((f) => f.sourcePod).map((f) => f.kind)
  );
  return latest
    .filter((f) => f.sourcePod || !kindsWithPod.has(f.kind))
    .filter((f) => flowVisibleOnPod(f, pods));
}

export function flowsGroupedByPod(
  flows: AttestationFlow[],
  pods: PodInfo[]
): Map<string, AttestationFlow[]> {
  const normalized = normalizeFlowsForDisplay(flows, pods);
  const map = new Map<string, AttestationFlow[]>();
  for (const f of normalized) {
    const key = f.sourcePod || "_unknown";
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push(f);
  }
  return map;
}
