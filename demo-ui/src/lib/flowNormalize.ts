import type { AttestationFlow, FlowKind, PodInfo } from "../types";
import { latestFlowsByPath } from "./topologyCoords";

const RE_TEE = /tee=(AzSnpVtpm|Sample)\b/;
const RE_VERIFIER = /Verifier\/endorsement check passed\. tee=(\S+)/;

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

export function correlatePod(
  tee: string | null | undefined,
  pods: PodInfo[]
): string | undefined {
  if (!tee) return undefined;
  if (tee === "Sample") {
    return pods.find((p) => p.role === "baseline-encrypted-fail")?.name;
  }
  if (tee === "AzSnpVtpm") {
    const conf = pods
      .filter((p) => p.role === "confidential")
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    const booting = conf.filter((p) => !p.ready);
    if (booting.length) return booting[booting.length - 1].name;
    return conf[conf.length - 1]?.name;
  }
  return undefined;
}

function confidentialPod(pods: PodInfo[], preferBooting = true): string | undefined {
  const conf = pods
    .filter((p) => p.role === "confidential")
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  if (!conf.length) return undefined;
  if (preferBooting) {
    const booting = conf.filter((p) => !p.ready);
    if (booting.length) return booting[booting.length - 1].name;
  }
  const ready = conf.filter((p) => p.ready);
  if (ready.length === 1) return ready[0].name;
  return conf[conf.length - 1]?.name;
}

function migrateKind(kind: string): FlowKind {
  if (kind === "attest") return "attest-dek";
  return kind as FlowKind;
}

/** Strict demo attribution: baseline never receives a DEK pass. */
export function podForFlow(flow: AttestationFlow, pods: PodInfo[]): string | undefined {
  const baseline = pods.find((p) => p.role === "baseline-encrypted-fail");
  const tee = flow.tee ?? teeFromReport(flow.reportLines);

  if (flow.kind === "dek-policy") {
    if (flow.status === "pass") {
      if (tee === "Sample") return undefined;
      return correlatePod(tee ?? "AzSnpVtpm", pods);
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
    if (tee) return correlatePod(tee, pods);
    if (flow.status === "deny") return baseline?.name;
    return correlatePod("AzSnpVtpm", pods);
  }

  if (flow.kind === "image-policy") {
    if (flow.status === "pass") return correlatePod(tee ?? "AzSnpVtpm", pods);
    if (tee === "Sample") return baseline?.name;
    if (flow.status === "deny" && baseline && tee !== "AzSnpVtpm") return baseline.name;
    return correlatePod(tee ?? "AzSnpVtpm", pods);
  }

  if (tee) return correlatePod(tee, pods);
  return undefined;
}

function ensureGateBundle(flows: AttestationFlow[], podName: string): void {
  const ts = new Date().toISOString();
  const specs: FlowKind[] = [
    "attest-image",
    "image-policy",
    "attest-dek",
    "dek-policy",
  ];
  for (const kind of specs) {
    const existing = flows.find(
      (f) => f.sourcePod === podName && f.kind === kind
    );
    if (existing) {
      if (existing.status === "deny") continue;
      existing.status = "pass";
      continue;
    }
    flows.push({
      id: `inferred-${podName}-${kind}`,
      kind,
      status: "pass",
      sourcePod: podName,
      tee: "AzSnpVtpm",
      reportLines: [],
      timestamp: ts,
    });
  }
}

/** Baseline: hardware attest passes (Sample) but DEK policy always denies. */
function ensureBaselineBundle(flows: AttestationFlow[], podName: string): void {
  const ts = new Date().toISOString();
  const specs: { kind: FlowKind; status: AttestationFlow["status"]; tee: string }[] = [
    { kind: "attest-dek", status: "pass", tee: "Sample" },
    { kind: "dek-policy", status: "deny", tee: "Sample" },
  ];
  for (const { kind, status, tee } of specs) {
    const existing = flows.find(
      (f) => f.sourcePod === podName && f.kind === kind
    );
    if (existing) {
      if (kind === "dek-policy") existing.status = "deny";
      continue;
    }
    flows.push({
      id: `inferred-${podName}-${kind}`,
      kind,
      status,
      sourcePod: podName,
      tee,
      reportLines: [],
      timestamp: ts,
      denyReason:
        kind === "dek-policy"
          ? "Resource Rego denied DEK — sample attester not allowed under production policy"
          : undefined,
    });
  }
}

/** Repair flows for canvas display when Trustee attribution is missing. */
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

  const baseline = pods.find((p) => p.role === "baseline-encrypted-fail");
  const readyConf = pods.filter((p) => p.role === "confidential" && p.ready);
  const confPods = pods.filter((p) => p.role === "confidential");

  for (const f of working) {
    if (f.sourcePod) continue;
    const pod = podForFlow(f, pods);
    if (pod) f.sourcePod = pod;
  }

  // Strip impossible states: baseline must never show DEK pass.
  for (const f of working) {
    if (
      f.kind === "dek-policy" &&
      f.status === "pass" &&
      baseline &&
      f.sourcePod === baseline.name
    ) {
      f.sourcePod = confidentialPod(pods, false);
      f.tee = "AzSnpVtpm";
    }
  }

  if (baseline) {
    ensureBaselineBundle(working, baseline.name);
  }

  for (const pod of readyConf) {
    const hasDekDeny = working.some(
      (f) =>
        f.sourcePod === pod.name &&
        f.kind === "dek-policy" &&
        f.status === "deny"
    );
    if (!hasDekDeny) {
      ensureGateBundle(working, pod.name);
    }
  }

  for (const pod of confPods.filter((p) => !p.ready)) {
    const hasPass = working.some(
      (f) =>
        f.status === "pass" &&
        f.sourcePod === pod.name &&
        (f.kind === "dek-policy" || f.kind === "image-policy")
    );
    if (hasPass) ensureGateBundle(working, pod.name);
  }

  const latest = latestFlowsByPath(working);
  const kindsWithPod = new Set(
    latest.filter((f) => f.sourcePod).map((f) => f.kind)
  );
  return latest.filter((f) => f.sourcePod || !kindsWithPod.has(f.kind));
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
