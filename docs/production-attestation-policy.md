# Production attestation policy (realistic, not “relax”)

Three layers must align. This doc replaces `make relax-resource-policy-snp` for production-style deployments.

## Why operator default Rego denied you

Your cluster had the **Trustee operator default** policy:

- `allow if count(input.submods) > 0` and EAR trust vectors are “affirming”
- `hardware_failing` when `ear.trustworthiness-vector.hardware` is not in range 2–31

You saw:

```text
tee=AzSnpVtpm
POST /attest 200        ← RVPS / endorsement OK
GET .../dek → PolicyDeny ← Rego denied (often hardware_failing for SNP)
```

That is **not** fixed by initdata alone. Initdata fixed SNP attestation (`tee=Sample` → `tee=AzSnpVtpm`). Rego is a separate gate.

| Approach | SNP-only | CVM-specific | EAR vectors | When |
|----------|----------|--------------|-------------|------|
| Operator default | No | No | Yes (+ hardware trap) | Breaks SNP without full TCB RVPS |
| `relax-resource-policy-snp` (demo) | Yes | No | No | Quick demo |
| **Production (this doc)** | Yes | **Yes (measurement + pcr11)** | Yes (exec/config) | Real deployments |

## Layer 1 — RVPS matches inference pod VM image

RVPS reference values come from the **OSC verity image** on the cluster where peer pods run, via coco-infra:

```bash
# Inference cluster (or same cluster as KBS for local demo)
make sync-trustee-attestation
```

That runs `configure-trustee.sh`, which:

1. Pulls `registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image`
2. Reads `measurements.json` from the pod VM image
3. Writes `trusteeconfig-rvps-reference-values`
4. Regenerates `initdata.toml` and reapplies peer-pods `INITDATA`

**When to re-run:** OSC upgrade, peer-pod VM image change, or initdata/KBS URL change.

Verify:

```bash
cd policy-dry-run
make check-rvps-initdata -- --cluster
```

## Layer 2 — Capture golden CVM fingerprints

After one **`tee=AzSnpVtpm`** attest (`POST /attest 200`), save the attestation token claims (JWT payload or `input.submods` JSON).

```bash
# One-time on OpenShift Sandboxed Containers peer pods (kata-remote):
make enable-peer-pods-guest-rest-api

# Real JWT → measurement + pcr11 via attest-probe (~15–30 min first CVM boot):
make capture-golden-claims
# → policy-dry-run/captured/cvm-pins-golden.json, input-golden.json
```

**Peer pods:** OSC `/etc/kata-containers/remote/configuration.toml` blocks `kernel_params` pod annotations by default. The enable script patches kata-oc workers to set global `agent.guest_components_rest_api=all`. Capture curls `/aa/token` from **inside** the probe pod (not host port-forward; not Trustee log grep).

Re-run `enable-peer-pods-guest-rest-api` after major OSC upgrades.

Offline transform if you already have a JWT file:

```bash
cd policy-dry-run
./capture-claims.sh --from /path/to/claims.json --label golden
```

Diagnose why operator default would deny the same token:

```bash
./diagnose-operator-policy.sh captured/input-golden-cvm.json
```

## Layer 3 — Generate and apply production Rego

```bash
bash scripts/kbs/generate-production-policy.sh \
  --pins policy-dry-run/captured/cvm-pins-golden-cvm.json

cd policy-dry-run
make dry-run-measurements -- \
  --rego ../policy/kbs-resource-policy-snp-production.rego \
  --fixture captured/input-golden-cvm.json \
  --require-pinning

# KBS cluster
bash scripts/kbs/apply-production-resource-policy.sh
```

Or one shot (RVPS + capture file + apply):

```bash
bash scripts/kbs/bootstrap-production-policy.sh --capture policy-dry-run/captured/input-golden-cvm.json
```

Production Rego requires:

- `az-snp-vtpm` in JWT (blocks sample baseline)
- **Pinned `measurement` + `pcr11`** from your golden guest
- EAR **executable** and **configuration** vectors affirming (operator semantics)
- **No** generic `hardware_failing` — replaced by stricter CVM pins (RVPS still validates hardware at verify time)

## Bootstrap if you cannot capture claims yet

```bash
bash scripts/kbs/bootstrap-production-policy.sh --temp-demo
```

Applies demo policy once so a guest can complete a cycle; then capture claims and re-run bootstrap without `--temp-demo`.

## After apply

```bash
make demo-act-ii
```

This restarts the golden confidential pod and verifies fresh attest + DEK GET **200** under pinned Rego (not warm memory).

Act III (mismatch replica): `make demo-act-iii`

Watch Trustee during Act II restart:

```bash
oc logs -n trustee-operator-system deployment/trustee-deployment -f \
  | grep -E 'tee=|confidential-inferencing-dek|PolicyDeny'
```

## When pod VM image changes

1. `make sync-trustee-attestation`
2. Re-capture claims from new golden boot
3. Regenerate + apply production policy
4. Delete confidential pods

## Related tools

| Tool | Purpose |
|------|---------|
| `policy-dry-run/diagnose-operator-policy.sh` | Why operator default allows/denies a fixture |
| `policy-dry-run/check-rvps-initdata.sh` | initdata ↔ RVPS ↔ cluster INITDATA |
| `scripts/kbs/generate-production-policy.sh` | Pins → Rego |
| `scripts/kbs/apply-production-resource-policy.sh` | Apply + restart Trustee |
| `make relax-resource-policy-snp` | Demo only — not production |
