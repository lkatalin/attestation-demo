export type Act = "prologue" | "i" | "ii" | "iii" | "unknown";

export interface PodInfo {
  name: string;
  role: string;
  phase: string;
  ready: boolean;
  runtimeClass: string;
  createdAt: string;
  restartCount: number;
  imagePulled?: boolean;
  containerStarted?: boolean;
  containerWaitingReason?: string;
  isGolden?: boolean;
}

export type FlowKind =
  | "kubelet-pull"
  | "attest-image"
  | "attest-dek"
  | "image-policy"
  | "dek-policy";
export type FlowStatus = "pending" | "verifying" | "pass" | "deny";

export interface AttestationFlow {
  id: string;
  kind: FlowKind;
  status: FlowStatus;
  tee?: string | null;
  sourcePod?: string | null;
  trigger?: string | null;
  httpCode?: number | null;
  policyName?: string | null;
  reportLines: string[];
  denyReason?: string | null;
  timestamp: string;
}

export interface TimelineEntry {
  ts: string;
  level: string;
  message: string;
}

export interface DemoState {
  connected: boolean;
  clusterUser: string;
  error: string | null;
  act: Act;
  defaultPrompt: string;
  kbs: {
    endpoint: string;
    resourcePolicy: string;
    imagePolicy: string;
    secrets: string[];
  };
  initdata: string;
  pods: PodInfo[];
  flows: AttestationFlow[];
  timeline: TimelineEntry[];
}
