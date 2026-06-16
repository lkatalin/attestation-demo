import type { AttestationFlow, FlowKind } from "../types";
import { isAttestKind } from "./gatePaths";

/** Trustee / KBS broker node (not a policy gate). */
export const ROLE_KBS = "var(--role-kbs)";

/** Confidential VM shell. */
export const ROLE_CVM = "var(--role-cvm)";

/** Hardware attestation paths (both gates). */
export const COLOR_ATTEST = "var(--color-attest)";

/** Image pull policy — paths, KBS gate, CVM outer vault. */
export const COLOR_IMAGE_POLICY = "var(--color-image-policy)";

/** DEK release policy — paths, KBS gate, CVM inner vault. */
export const COLOR_DEK_POLICY = "var(--color-dek-policy)";

export const COLOR_DENY = "var(--neon-magenta)";

export function policyColor(kind: FlowKind): string {
  switch (kind) {
    case "image-policy":
      return COLOR_IMAGE_POLICY;
    case "dek-policy":
      return COLOR_DEK_POLICY;
    default:
      return COLOR_ATTEST;
  }
}

export function pathStrokeColor(flow: AttestationFlow): string {
  if (flow.status === "deny") return COLOR_DENY;
  if (flow.status === "verifying" && isAttestKind(flow.kind)) {
    return COLOR_ATTEST;
  }
  if (isAttestKind(flow.kind)) {
    return COLOR_ATTEST;
  }
  return policyColor(flow.kind);
}

export function pathGlowFilter(flow: AttestationFlow): string | undefined {
  if (flow.status === "deny") return "url(#glow-magenta)";
  if (flow.status !== "pass") return undefined;

  switch (flow.kind as string) {
    case "attest-image":
    case "attest-dek":
    case "attest":
      return "url(#glow-amber)";
    case "image-policy":
      return "url(#glow-violet)";
    case "dek-policy":
      return "url(#glow-lime)";
    default:
      return undefined;
  }
}
