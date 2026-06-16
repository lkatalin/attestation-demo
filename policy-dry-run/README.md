# Attestation policy dry-run

Offline checks for **KBS resource Rego**, **Sigstore image verification JSON**, and **KBS handoff bundles** — before you apply policy or deploy the full inference stack.

Use this to catch the most common production failure: **Trustee logs say `tee=AzSnpVtpm` but Rego must read `az-snp-vtpm` in the JWT**. Verification can pass while every resource GET returns `401 PolicyDeny`.

## Recommended workflow (before full deploy)

Attestation security has **three KBS touchpoints** in a peer pod, not one. Dry-run and handoff checks cover the **policy layers**; the table below explains **who attests** for each step so you do not debug the wrong path.

| Touchpoint | When | Who attests | Config source | Dry-run / cluster check |
|------------|------|-------------|---------------|-------------------------|
| **Image pull** | Guest boot, before your container starts | CDH + guest **Attestation Agent** | `initdata.toml` → `cdh.toml`, `aa.toml` | `dry-run.sh --verification …`; Trustee `GET …/trustee-image-policy/policy` **200** |
| **Runtime DEK** | Your entrypoint at container start | CDH (via **REST API** in pod netns) | Entrypoint + optional `[[credentials]]` in `cdh.toml` | `dry-run.sh` stack checks; Trustee `GET …/confidential-inferencing-dek/dek` **200** with `tee=AzSnpVtpm` |
| **Baseline failure** | Worker pod, no CVM | `kbs-client` → **sample** fallback | Same image, wrong runtime | `dry-run.sh` sample fixture → deny; baseline pod CrashLoop |

**Common first-time trap:** image pull succeeds (`tee=AzSnpVtpm`, policy GET **200**) but the confidential pod still CrashLoops on DEK. That usually means the **runtime DEK path** is wrong — not Rego, not cosign. See [Runtime DEK fetch (workload container)](#runtime-dek-fetch-workload-container) below.

Attestation security also has **two policy layers**. Both must pass; dry-run helps with each at different stages.

| Layer | Where configured | What it checks | Tool in this directory |
|-------|------------------|----------------|------------------------|
| **Reference values / endorsement** | Trustee **RVPS** + guest **initdata** (coco-infra `configure-trustee.sh`) | Guest launch measurement matches an **endorsed** reference for your pod VM image | `check-handoff.sh` (URL/cert alignment); RVPS regen on image change |
| **Resource release** | KBS **Rego** (`trusteeconfig-resource-policy`) | Which attestation tokens may **read secrets** (DEK) | `dry-run.sh` |
| **Image pull** | KBS **Sigstore JSON** (`trustee-image-policy`) | Which **cosign-signed** images CDH may pull | `dry-run.sh --verification … --image …` |

```text
1. Write / edit Rego + verification JSON locally
2. make dry-run                    ← naming, structure, synthetic fixtures, DEK fetch stack
3. make check-handoff BUNDLE=…     ← kbs.url ↔ initdata ↔ ca.pem (no inference deploy)
4. (optional) One minimal guest attest → capture-claims.sh → re-run dry-run with captured fixture
5. make apply-resource-policy      ← KBS cluster only
6. Deploy confidential pod only    ← skip baseline/plaintext until policy proven
7. make measure-attestation        ← live matrix (parent repo; needs both clusters)
```

Steps 1–3 need **no guest pod**. Step 4 needs **one** successful attest (probe pod or confidential pod) but not the full demo.

## Quick start

```bash
cd policy-dry-run
make dry-run          # policy + DEK stack
make production       # full offline production suite (see policy-dry-run/README.md)
make check-handoff    # if kbs-tee-attestation/output/ exists
```

With a specific image for the verification-policy template:

```bash
IMAGE=quay.io/you/confidential-inferencing-demo:latest \
  ./dry-run.sh --verification ../kbs-tee-attestation/policy/verification-policy.template.json
```

Custom Rego only:

```bash
./dry-run.sh --rego /path/to/my-resource-policy.rego
```

**OPA:** evaluation uses the `opa` CLI if installed, otherwise `docker run openpolicyagent/opa:latest`. Static checks always run. Use `--skip-opa` or `make dry-run-static` when OPA is unavailable.

## Getting measurements for policy

### What measurements are, and where they are checked

For AMD SNP peer pods, attestation tokens include (under `az-snp-vtpm`):

| Field | Meaning |
|-------|---------|
| `measurement` | SNP launch digest of the confidential VM |
| `tpm.pcr11` | vTPM PCR binding firmware + guest state |

**Default demo Rego** only checks that `az-snp-vtpm` **exists** — enough to block `sample` on worker nodes.

**Stronger Rego** can also **pin** `measurement` and/or `pcr11` so only a specific pod VM build gets the DEK. See [`examples/kbs-resource-policy-snp-measurements.rego`](examples/kbs-resource-policy-snp-measurements.rego).

**RVPS** (Trustee reference values) performs endorsement verification **before** Rego runs. If RVPS/initdata do not match the inference cluster’s peer-pod VM image, attest fails at `Verifier/endorsement` — no Rego tweak fixes that. Regenerate via coco-infra `configure-trustee.sh` when the pod VM image changes.

### Capture claims from a real attest

After **one** successful guest attestation, save the JWT or the KBS evaluation `input` JSON (from Trustee debug logs, support bundle, or a manual attest probe).

```bash
# From saved claims JSON (input.submods shape)
./capture-claims.sh --from /path/to/claims.json --label prod-cvm

# From JWT file
./capture-claims.sh --from-jwt /path/to/token.jwt --label prod-cvm
```

Outputs under `captured/`:

| File | Purpose |
|------|---------|
| `input-<label>.json` | OPA input fixture (real submods) |
| `measurements-<label>.json` | Raw evidence summary |
| `rego-measurements-<label>.rego` | Suggested pin rules with your hex values |

Re-test policy against captured data:

```bash
./dry-run.sh \
  --rego examples/kbs-resource-policy-snp-measurements.rego \
  --fixture captured/input-prod-cvm.json
```

Replace `MEASUREMENT_HEX` / `PCR11_HEX` in the example Rego with captured values before apply.

### Where to get claims without full inference deploy

| Method | Needs | Notes |
|--------|-------|-------|
| **capture-claims.sh** | One saved JWT or claims JSON | Best for pinning Rego |
| **make measure-attestation** (parent repo) | Confidential + baseline pods running | Shows `tee=` and GET status, not full claim JSON |
| **Trustee logs** | Pod restart after policy apply | `Verifier/endorsement check passed. tee=AzSnpVtpm` — log label only, not measurement hex |
| **RVPS / initdata** | coco-infra Trustee setup | Ensures endorsement layer matches pod VM image; not a substitute for Rego |

The doc reference to `scripts/kbs/attest-probe-pod.yaml` is implemented; use:

```bash
make enable-peer-pods-guest-rest-api   # once per cluster (OSC peer pods)
make capture-golden-claims             # attest-probe → real JWT → cvm-pins-golden.json
```

Trustee log scrape remains a fallback in `capture-golden-from-pod.sh` only — not for production pinning.

## Cross-cluster customer handoff

When KBS and the DEK live on the **model owner** cluster and the customer runs inference elsewhere, use `customer-handoff.sh` for both directions.

| Direction | Command | Who runs it |
|-----------|---------|-------------|
| Model owner → customer | `make customer-handoff-export-bundle` | KBS operator |
| Customer validates | `make customer-handoff-import-bundle PACK=…` | Inference team |
| Customer → model owner (pins) | `make customer-handoff-export-claims FROM=… LABEL=…` | Customer after golden SNP boot |
| Model owner validates pins | `make customer-handoff-import-claims PACK=…` | Model owner |

**Customer claims pack** includes only `measurement`, `pcr11`, OPA input fixture, and optional non-secret cluster metadata — not DEK, JWTs, or workload data. See `HANDOFF_README.txt` inside each tarball.

```bash
# Model owner (after kbs-tee-attestation configure + export-endpoint)
cd policy-dry-run
IMAGE=quay.io/you/model:latest make customer-handoff-export-bundle

# Customer (before remote deploy)
make customer-handoff-import-bundle PACK=customer-handoff/model-owner-kbs-bundle.tar.gz

# Customer (after one good confidential boot — save KBS eval input or JWT once)
make customer-handoff-export-claims FROM=/tmp/claims.json LABEL=acme-prod CLUSTER_INFO=1

# Model owner (generate pinned policy)
make customer-handoff-import-claims PACK=customer-handoff/customer-claims-acme-prod.tar.gz
cd .. && make generate-production-policy PINS=policy-dry-run/customer-handoff/imported-acme-prod/cvm-pins.json
make apply-production-resource-policy
```

For **demo** on a new cluster you usually only need SNP-only policy (`relax-resource-policy-snp`), not per-customer pins — see workflow below.

## Handoff bundle checks (no inference deploy)

Before the inference team applies initdata + `KBS_URL`:

```bash
./check-handoff.sh ../kbs-tee-attestation/output

# or explicit paths
./check-handoff.sh --kbs-url "$(cat output/kbs.url)" \
  --ca output/kbs-ca.pem --initdata output/initdata.toml \
  --deploy-env ../deploy/kbs.env
```

Checks:

- Required files present (`kbs.url`, `kbs-ca.pem`, `initdata.toml`, resource path)
- **Host in `kbs.url` matches URLs embedded in `initdata.toml`**
- Optional: `deploy/kbs.env` `KBS_URL` matches
- Optional: KBS `/health` reachable from your laptop

Misaligned initdata vs pod env is a common cause of “attest works for image pull but DEK path fails” (or vice versa).

## Runtime DEK fetch (workload container)

Image pull and runtime DEK unlock are **different code paths** inside the confidential VM. First-time setup often passes the first and fails the second.

### Why `cdh.sock` is not enough

| Mechanism | Path | Visible to workload container? |
|-----------|------|--------------------------------|
| CDH **unix socket** | `/run/confidential-containers/cdh.sock` | Usually **no** — lives in the guest sandbox mount namespace, not the app container’s |
| CDH **REST API** | `http://127.0.0.1:8006/cdh/resource/{tenant}/{resource}/{key}` | **Yes** — CDH shares the **pod network namespace** ([CoCo get-resource docs](https://confidentialcontainers.org/docs/features/get-resource/)) |
| Boot-prefetched credential file | `/run/confidential-containers/cdh/kbs/…` | Often **no** — same mount-namespace isolation as the socket |
| **`kbs-client` in entrypoint** | Direct KBS RCAR from app container | **Fails on CVM** — no vTPM in the workload container → sample attester → Rego deny |

The reference entrypoint tries **REST first**, then socket, then credential file, then `kbs-client` (baseline / non-CVM only). `dry-run.sh` warns if the repo entrypoint or deployment drifts from this.

### Do not mount hostPath on `/run/confidential-containers`

A Kubernetes **hostPath** from the worker node mounts the **node’s** (empty) directory over the guest path and **hides** the real CDH socket and credential files. Do not use hostPath to “expose” CDH to the workload — use the REST API instead.

### OpenShift SCC (`kata-remote`)

Peer pods use `runtimeClassName: kata-remote` → SCC `sandboxed-containers-operator-scc` with **`MustRunAsNonRoot`**. The inference image should declare `USER 1001` (or similar) in the Dockerfile so you do not need `runAsUser` in the Deployment. `dry-run.sh` checks both.

### Boot `[[credentials]]` in initdata (optional)

`cdh.toml` can prefetch the DEK at guest boot into `/run/confidential-containers/cdh/kbs/…`. On some platforms CDH starts **before** vTPM is ready → sample attestation → PolicyDeny at boot. Runtime REST fetch after the guest is up is more reliable; boot prefetch is a best-effort fallback.

### Symptom → cause (runtime DEK)

| Pod log / Trustee | Likely cause | Fix |
|-------------------|--------------|-----|
| `Waiting for CDH socket` → `fallback to kbs-client` → `Sample Attester` → `PolicyDeny` | App used socket/kbs-client, not REST | Entrypoint must call CDH REST on `127.0.0.1:8006` |
| Image pull OK, DEK GET never appears in Trustee | DEK fetch never reached CDH/AA | Same as above |
| `hostPath volumes are not allowed` | hostPath on CDH mount | Remove hostPath; use REST API |
| `runAsNonRoot and image will run as root` | Image USER unset on kata-remote | Add `USER 1001` to Dockerfile |
| `GET …/dek` **200** with `tee=Sample` | Wrong attester (worker or early boot) | Confidential pod must be `kata-remote`; avoid relying on boot prefetch only |

## What the dry-run checks

### 1. TEE naming — PascalCase (logs) vs kebab-case (JWT)

Trustee verification logs print the Rust `Tee` enum name. The attestation token stores platform evidence under **serde rename** keys in `ear.veraison.annotated-evidence`.

| Trustee log (`tee=`) | JWT / Rego key | Notes |
|----------------------|----------------|-------|
| `AzSnpVtpm` | `az-snp-vtpm` | AMD SNP peer-pod CVM (this demo) |
| `Sample` | `sample` | `kbs-client` fallback without hardware attester |
| `Tdx` | `tdx` | Intel TDX |
| `Snp` | `snp` | Generic SNP |

**Dry-run fails if Rego uses PascalCase keys** (e.g. `["AzSnpVtpm"]`) in evidence paths, or mentions `AzSnpVtpm` without also referencing `az-snp-vtpm`.

Full mapping: [`tee-naming-map.json`](tee-naming-map.json).

**Strong policy rule:** always key off `input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]` (or your platform’s token key), never the log label.

### 2. Rego structure (deny-by-default)

| Check | Why it matters |
|-------|----------------|
| `package policy` | KBS resource plugin loads this package name |
| `default allow = false` | Without it, unspecified cases may allow secret release |
| `data.plugin == "resource"` | Avoids accidental matches on other plugins |
| No `count(input.submods) > 0` | Allows **sample-only** baseline guests on worker nodes to decrypt the DEK |

### 3. OPA evaluation against fixtures

Fixtures under [`fixtures/`](fixtures/) match the shape in [docs/attestation-and-policy.md](../docs/attestation-and-policy.md).

| Fixture | Simulates | Strong SNP policy should |
|---------|-----------|---------------------------|
| `input-snp-cvm.json` | Confidential peer-pod guest | **Allow** |
| `input-sample-only.json` | Worker node, sample attester | **Deny** |
| `input-empty-submods.json` | Broken / empty token | **Deny** |
| `input-snp-and-sample.json` | SNP + sample in same token | **Allow** if SNP key is sufficient |

Request metadata (`data.plugin`, `data.resource-path`) comes from [`fixtures/data-resource-dek.json`](fixtures/data-resource-dek.json) (`default/confidential-inferencing-dek/dek`).

### 4. Sigstore verification policy (image pull)

Validates `verification-policy.template.json` (or your copy):

| Check | Why it matters |
|-------|----------------|
| Valid JSON | KBS rejects malformed policy secrets |
| `default: [{ "type": "reject" }]` | Unsigned images must not pull |
| `keyPath: kbs:///…` | CDH resolves cosign keys via KBS resources |
| `__IMAGE_REF__` substituted when `IMAGE` is set | Template must map to your pushed image repo + tag |
| References `confidential-inferencing-signature` | Matches registered cosign pub-key resource |

Image policy is separate from resource Rego but equally required for the TEE: CDH pulls the signed workload via `kbs:///default/trustee-image-policy/policy` using initdata-embedded KBS URL.

### 5. Cross-stack consistency

| Layer | Must align | Tool |
|-------|------------|------|
| **Guest attester** | `kbs-client` built with `az-snp-vtpm-attester` (fallback only) | Build scripts in parent repo; `dry-run.sh` stack check |
| **Runtime DEK path** | Entrypoint uses CDH REST before socket / direct `kbs-client` | `dry-run.sh` stack check |
| **Initdata / RVPS** | Measurements match peer-pod VM image | coco-infra `configure-trustee.sh`; `check-handoff.sh` |
| **KBS URL** | Same in `initdata.toml`, pod `KBS_URL`, `output/kbs.url` | `check-handoff.sh` |
| **Resource path** | Rego protects same path as `KBS_RESOURCE_PATH` / CDH REST path | `fixtures/data-resource-dek.json`; `check-handoff.sh` |
| **Cosign** | Image signed with registered pubkey | `dry-run.sh --verification … --image …` |
| **Image USER** | Non-root USER in Dockerfile for `kata-remote` SCC | `dry-run.sh` stack check |

### 6. Runtime DEK fetch stack (repo layout)

| Check | Why it matters |
|-------|----------------|
| `fetch_dek_via_cdh_rest` in `container/entrypoint.sh` | Workload containers reach CDH via pod netns REST, not `cdh.sock` |
| `USER` set in `container/Dockerfile` | `sandboxed-containers-operator-scc` rejects root-default images |
| No `hostPath` on `/run/confidential-containers` in deployment | hostPath masks guest CDH paths with the worker node directory |
| Optional: no redundant `runAsUser` in deployment | Prefer image metadata over manifest duplication |

## Production dry-run suite

For production (or staging promote gates), run the full offline suite:

```bash
cd policy-dry-run
make production              # all offline checks
make production-strict       # warnings fail the run (recommended CI)
make production-cluster      # + oc login: policy drift, initdata hash, Trustee log scrape
```

Or run `./run-production-checks.sh` directly. Individual scripts are also available via `make help`.

### Tool reference

| Script | Offline? | Needs `oc`? | What it validates |
|--------|----------|-------------|-------------------|
| **`dry-run.sh`** | Yes | No | Rego naming/structure, OPA fixtures, Sigstore JSON, DEK fetch stack |
| **`check-handoff.sh`** | Yes | No* | `kbs.url`, initdata URLs, CA, CDH blocks, DEK path in initdata |
| **`check-workload-kbs-path.sh`** | Yes | No | CDH REST before socket/kbs-client, Dockerfile USER, no hostPath, probe timing |
| **`check-rvps-initdata.sh`** | Yes | Optional | initdata structure/hash; `--cluster` compares to `peer-pods-cm` INITDATA |
| **`check-remote-contract.sh`** | Yes | Optional | Handoff + `deploy/kbs.env` + deployment substitution + TLS expiry |
| **`check-image-contract.sh`** | Partial | No | cosign verify, `:latest` warn, digest pin, no secrets in Dockerfile; skopeo if installed |
| **`dry-run-measurements.sh`** | Yes | No | Measurement-pinned Rego; `--require-pinning` for prod CI |
| **`check-kbs-tenancy.sh`** | Yes | No | Deny-by-default, no `count(submods)`, az-snp-vtpm required, path alignment |
| **`diff-cluster-policy.sh`** | No | **Yes** | Live `trusteeconfig-resource-policy` + image policy secret vs git |
| **`dry-run-rotation.sh`** | Yes | No | Cosign/DEK/CA artifacts present; cert horizon; rotation runbook checklist |
| **`check-platform-policy.sh`** | Yes | Optional | kata-remote, hostPath/privileged, dedicated SA; SCC binding if oc |
| **`check-attestation-slo.sh`** | Yes | Optional | Expected Trustee log patterns; `--scrape-logs` greps live logs |
| **`run-production-checks.sh`** | Yes | Optional | Orchestrates all of the above |

\* `check-handoff.sh --probe` / health checks use curl when requested.

### Suggested production pipeline

```text
PR / build (CI, no cluster)
  make production-strict IMAGE=quay.io/org/model@sha256:…

Promote to staging
  make check-remote-contract
  make check-rvps-initdata --cluster
  capture-claims.sh → dry-run-measurements.sh --require-pinning

Pre-prod change window (oc login to KBS cluster)
  make diff-cluster-policy
  make check-attestation-slo --scrape-logs

Quarterly
  make dry-run-rotation --min-cert-days 90
```

### Examples

```bash
# Image gate with legacy .sig check (needs network + skopeo)
IMAGE=quay.io/org/model:v1.2.3 make check-image-contract CHECK_SIG=1
./check-image-contract.sh --image "$IMAGE" --check-sig-tag

# Pin measurement Rego before prod apply
./capture-claims.sh --from captured/input-staging.json --label staging
./dry-run-measurements.sh --rego policy/prod-pinned.rego \
  --fixture captured/input-staging.json --require-pinning --strict

# Detect policy drift
oc login …
./diff-cluster-policy.sh --strict

# RVPS / initdata drift
./check-rvps-initdata.sh --initdata ../coco-infra/aro/trustee/initdata.toml --cluster
```

## Expected outcomes for reference policies

These repo policies should pass all dry-run checks:

- `kbs-tee-attestation/policy/kbs-resource-policy-snp.rego`
- `policy/kbs-resource-policy-snp-demo.rego`

## Interpreting failures

| Dry-run message | Typical cause |
|-----------------|---------------|
| PascalCase tee key in Rego | Copied `AzSnpVtpm` from Trustee logs into policy |
| sample-only fixture → allow | Policy too loose (`count(submods)` or missing TEE check) |
| SNP fixture → deny | Wrong claim path, typo in `az-snp-vtpm`, or missing `package policy` |
| `__IMAGE_REF__` not substituted | Run with `--image` / `IMAGE=` matching `operator.env` |
| OPA skipped | Install [OPA](https://www.openpolicyagent.org/docs/latest/#running-opa) or Docker for eval |
| entrypoint may not use CDH REST | Workload will miss DEK even when image pull attestation passes |
| hostPath on guest CDH paths | Masks real CDH socket; remove mount, use REST API |
| Dockerfile has no USER | kata-remote pod rejected or needs manifest `runAsUser` |

## Relation to cluster verify

| Tool | When |
|------|------|
| **`run-production-checks.sh`** | CI / pre-promote — full offline production gate |
| **`dry-run.sh`** | Before apply — Rego + image policy + synthetic/captured fixtures |
| **`check-handoff.sh`** | Before inference deploy — `output/` bundle consistency |
| **`check-remote-contract.sh`** | Cross-cluster handoff + TLS + deployment alignment |
| **`diff-cluster-policy.sh`** | Pre-change window — git vs live KBS policy |
| **`check-rvps-initdata.sh --cluster`** | After pod VM image or initdata change |
| **`capture-claims.sh`** | After one real attest — measurement pins + custom fixtures |
| **`check-attestation-slo.sh --scrape-logs`** | Post-deploy — Trustee log patterns |
| **`kbs-tee-attestation/scripts/verify.sh`** | After KBS configure — health, secrets, route |
| **`make measure-attestation`** | After pods running — live behavior matrix |

Run `make production-strict` in CI on Rego, entrypoint, or deployment changes; run `make production-cluster` before prod promote; run measure-attestation to validate end-to-end.

## Directory layout

```
policy-dry-run/
  run-production-checks.sh     orchestrate all production gates
  dry-run.sh                   Rego + verification policy + DEK stack
  check-workload-kbs-path.sh   CDH REST / USER / hostPath / probes
  check-rvps-initdata.sh       initdata ↔ RVPS ↔ cluster INITDATA
  check-remote-contract.sh     handoff + TLS + remote KBS contract
  check-image-contract.sh      cosign, digest pin, supply chain
  diff-cluster-policy.sh       git vs live policy drift (oc)
  check-kbs-tenancy.sh         blast-radius / deny-by-default
  dry-run-measurements.sh      measurement-pinned Rego + OPA
  dry-run-rotation.sh          rotation tabletop
  check-platform-policy.sh     OpenShift SCC / kata-remote
  check-attestation-slo.sh     observability / Trustee log patterns
  capture-claims.sh            JWT/claims → fixtures + measurement Rego
  customer-handoff.sh          cross-cluster packs (KBS bundle + claims pins)
  check-handoff.sh             kbs.url / initdata / ca.pem alignment
  lib/common.sh                shared logging + helpers
  tee-naming-map.json          log label ↔ JWT key reference
  fixtures/                    synthetic inputs + expected-trustee-log-patterns.txt
  captured/                    gitignored; real captured fixtures
  examples/                    bad-pascal-case.rego, measurement-pinned template
  Makefile
  README.md
```

## Options

```
./dry-run.sh [--rego PATH ...] [--verification PATH] [--image REF]
             [--fixture PATH ...] [--strict] [--verbose] [--skip-opa]
```

`--strict` turns warnings into failures (recommended in CI).
