# Confidential inferencing demo

Encrypted model weights, **DEK in KBS**, inference in a **confidential VM** (`kata-remote`). One image, three deployments (confidential / plaintext / baseline) for live demos.

Default image: `quay.io/lgallett/confidential-inferencing-demo:latest` (`export IMAGE=...` to override).  
ARO region: **`eastus`** in coco-infra ([why not eastus2](../coco-infra/README.md#azure-region-location)).

---

## Setup: local demo (one cluster)

Everything on a single ARO cluster: coco-infra (Trustee + peer pods) + this repo.

### Before you start

- Azure CLI + `oc`, logged in with cluster admin
- `docker` or `podman` (daemon running), `cosign`, `jq`, `envsubst`, Python 3.10+
- `docker login quay.io`
- coco-infra prerequisites: `~/.azure/osServicePrincipal.json`, `~/pull-secret.json` ([coco-infra README](../coco-infra/README.md))

### Commands

**1. Cluster + CoCo (~1.5 h)**

```bash
cd ../coco-infra/aro
bash setup.sh
oc login <api-url> -u kubeadmin -p <password>
```

If step 5 fails on `initdata.toml`:

```bash
export INITDATA_PATH="$(cd ../coco-infra/aro/trustee && pwd)/initdata.toml"
cd ../coco-infra/aro && OSC_ENV=aro bash configure-osc.sh
```

**2. Laptop: train, encrypt, build image**

```bash
cd confidential-inferencing
docker login quay.io
make laptop-prep
```

**3. KBS, SNP resource policy, deploy**

Both secrets are required (`register-policy` does **not** register the DEK):

```bash
oc login <same-cluster>
make local-register-dek      # DEK → KBS
make local-register-policy   # cosign policy + pub key → KBS
make relax-resource-policy-snp   # KBS policy: AzSnpVtpm yes, sample no (see docs/attestation-and-policy.md)
make fix-peer-pods
make local-deploy
```

**Before first deploy (offline, ~30 s):** catch Rego naming bugs and DEK-path mistakes early:

```bash
cd policy-dry-run
make production-strict   # full offline gate (or make dry-run for policy-only)
make check-handoff         # if kbs-tee-attestation/output/ or operator bundle exists
```

See [policy-dry-run/README.md](policy-dry-run/README.md) for the three KBS touchpoints (image pull vs runtime DEK vs baseline).

Or one target (includes the above + demo):

```bash
make local-cluster
```

**4. If confidential pod still fails**

Watch Trustee while the pod is `ContainerCreating` (logs appear in **seconds**, not after the pod is Running):

```bash
oc logs -n trustee-operator-system deployment/trustee-deployment -f \
  | grep -E 'Verifier|attest|trustee-image-policy|PolicyDeny|sigstore'
```

| Symptom in Trustee / pod events | Fix |
|--------------------------------|-----|
| `Verifier/endorsement check passed. tee=AzSnpVtpm` + `attest 200` + **`PolicyDeny`** on `trustee-image-policy/policy` | Rego used wrong claim key (`AzSnpVtpm` vs token `az-snp-vtpm`) | `make relax-resource-policy-snp` (policy checks `annotated-evidence["az-snp-vtpm"]`) |
| Image pull **200**, pod logs `Waiting for CDH socket` → `fallback to kbs-client` → `Sample Attester` → **`PolicyDeny`** on DEK | Runtime DEK path wrong — workload cannot use `cdh.sock` or entrypoint `kbs-client` | Entrypoint must use CDH REST `http://127.0.0.1:8006/cdh/resource/…`; see [policy-dry-run/README.md](policy-dry-run/README.md#runtime-dek-fetch-workload-container) |
| `hostPath volumes are not allowed` on confidential pod | hostPath mount for CDH (wrong approach) | Remove hostPath; use CDH REST API |
| `runAsNonRoot and image will run as root` | Image has no `USER` on `kata-remote` | Rebuild with `USER 1001` in Dockerfile |
| `GET .../trustee-image-policy/policy` **200** but pod: **`sigstoreSigned` rule** / image policy rejected | `make fix-image-sign` (legacy `.sig` tag; cosign v3 bundle referrers are not supported by CDH) |
| No `attest` lines at all | `make sync-trustee-attestation` (refresh RVPS + peer-pods initdata) |
| `InvalidParameter` / DC VM size in `oc describe pod` | [coco-infra Azure region](../coco-infra/README.md#azure-region-location), `make fix-peer-pods` |
| Two confidential pods stuck | `oc scale deployment inference-confidential -n confidential-inferencing --replicas=1` and delete old pods |

**5. Present**

```bash
make demo
```

### Verify local setup

| Check | Command | Good sign |
|-------|---------|-----------|
| CoCo runtime | `oc get runtimeclass kata-remote` | Resource exists |
| Kata worker | `oc get nodes -l workerType=kataWorker` | One node in `eastus-2` or `eastus-1` |
| Peer pods region | `oc get cm peer-pods-cm -n openshift-sandboxed-containers-operator -o jsonpath='{.data.AZURE_REGION}{"\n"}{.data.AZURE_INSTANCE_SIZE}{"\n"}'` | `eastus` + `Standard_DC4as_v5` |
| DEK in KBS | `oc get secret confidential-inferencing-dek -n trustee-operator-system` | Secret exists |
| Image policy | `oc get secret trustee-image-policy -n trustee-operator-system` | Secret exists |
| Image signed | `cosign verify --key artifacts/cosign.pub $IMAGE` | Verification succeeds |
| Legacy `.sig` tag | `skopeo list-tags docker://$IMAGE \| grep '\\.sig'` | Tag for current digest (CDH needs cosign **v2** `.sig`, not v3 bundle only) |
| Pods | `oc get pods -n confidential-inferencing` | `inference-confidential` **Running**, `inference-plaintext` **Running**, `inference-baseline-encrypted` **CrashLoop** |
| Confidential path | `curl -sk https://$(oc get route inference-confidential -n confidential-inferencing -o jsonpath='{.spec.host}')/demo/info` | `"demo_runtime":"confidential"` |
| Trustee policy | `oc logs -n trustee-operator-system deployment/trustee-deployment --tail=30 \| grep trustee-image-policy` | `GET .../trustee-image-policy/policy` **200** (after `relax-resource-policy-snp`) |
| Trustee attest | same logs | `Verifier/endorsement check passed. tee=AzSnpVtpm` and `POST /attest` **200** |

---

## Setup: remote KBS demo (cross-cluster)

**Model** runs on **your** inference cluster; **DEK + policy** live on **another** team’s KBS. They need `artifacts/operator-bundle/` (includes `dek.bin`).

### Model owner — laptop

```bash
make laptop-prep
make export-operator-bundle
```

Send them `artifacts/operator-bundle/` (tar/zip is fine).

### KBS operator — their cluster

```bash
# Copy bundle into this repo (or set OPERATOR_BUNDLE=/path/to/bundle)
cp config/operator.env.example config/operator.env
# edit IMAGE if needed
set -a && source config/operator.env && set +a

oc login <operator-cluster>
make operator-register-policy
make operator-register-dek
make relax-resource-policy-snp
make operator-export-kbs-endpoint
```

(`relax-resource-policy-snp` is the same SNP fix as the local demo; required on the KBS cluster.)

Send back to model owner: **`kbs.url`**, **`kbs-ca.pem`**, **`initdata.toml`**, **`kbs-resource-path.txt`** (all under `artifacts/operator-bundle/`).

### Model owner — inference cluster

```bash
cp config/inference-remote.env.example config/inference-remote.env
# Set KBS_URL, KBS_CA_FILE, INITDATA_PATH to operator files
set -a && source config/inference-remote.env && set +a

oc login <inference-cluster>
make remote-apply-initdata
make fix-peer-pods
make remote-deploy
make demo
```

Or: `make remote-cluster` after `source config/inference-remote.env`.

### Verify remote setup

| Check | Who | Command | Good sign |
|-------|-----|---------|-----------|
| DEK on operator KBS | Operator | `oc get secret confidential-inferencing-dek -n trustee-operator-system` | Exists |
| Policy on operator KBS | Operator | `oc get secret trustee-image-policy -n trustee-operator-system` | Exists |
| KBS reachable | Model owner | `curl -sk "$(cat artifacts/operator-bundle/kbs.url)/kbs/v0/health" \| head` | HTTP response (not connection refused) |
| Inference uses remote KBS | Model owner | `oc get deploy inference-confidential -n confidential-inferencing -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KBS_URL")].value}{"\n"}'` | Operator’s `kbs.url` |
| Peer initdata | Model owner | `gunzip -c <(oc get cm peer-pods-cm -n openshift-sandboxed-containers-operator -o jsonpath='{.data.INITDATA}' \| base64 -d) \| grep -m1 'url = '` | Same host as `kbs.url` |
| Confidential pod | Model owner | `oc get pods -n confidential-inferencing -l app=inference-confidential` | **Running** |
| Attestation to remote KBS | Operator | `oc logs -n trustee-operator-system deployment/trustee-deployment -f \| grep confidential-inferencing-dek` | Successful resource GET after attest (not only `PolicyDeny`) |

More detail: [config/README.md](config/README.md). All targets: `make help`.

---

## Prerequisites (reference)

coco-infra `setup.sh` needs **`eastus`** for `Standard_DC*as_v5` peer pods. Laptop needs a running container engine.

### While coco-infra is still running

You can build the image before the cluster is ready:

```bash
docker login quay.io
make laptop-prep
```

### Container engine (Docker / Podman) on macOS

`make build` needs a **running** daemon. Client-only installs are not enough.

| Symptom | Likely cause | Fix |
|---------|----------------|-----|
| `Cannot connect to the Docker daemon` | Docker Desktop not started | `open -a Docker` and wait until `docker info` works |
| `context deadline exceeded` | Docker Desktop stuck or VM wedged | Quit Docker → reopen; or **Troubleshoot → Restart** in Docker Desktop |
| Podman `connection refused` | Podman machine stopped | `podman machine start` then `podman info` |

Scripts auto-use **docker** if its daemon is up, else **podman**. Override with:

```bash
CONTAINER_ENGINE=podman make build
```

Reinstall Docker Desktop only if restart/reset does not help: [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/). **Podman Desktop** is a fine alternative for `make laptop-prep` (`brew install podman` + `podman machine init && podman machine start`).

**Build error `unknown type application/vnd.unknown.config.v1+json` on `kbs-client`:**  
`ghcr.io/.../kbs-client` is an **ORAS binary artifact**, not a Docker image. The Dockerfile uses `.../kbs-client-image:latest` instead. Builds target `linux/amd64` for ARO (`BUILD_PLATFORM` to override).

**Build error `no space left on device` but Mac has 50GB+ free:**  
Docker Desktop uses a **separate virtual disk** (often 64GB). When *that* is full, layer extraction fails even though macOS is fine.

```bash
bash scripts/docker-diagnose.sh    # see images, volumes, build cache
bash scripts/docker-prune-demo.sh  # prune cache/images/volumes (interactive)
```

Typical culprits: old **Kind** volumes (tens of GB), **llama-stack** images, build cache. This inference image also needs ~2–3GB during `pip install torch`. After pruning, raise the limit: **Docker Desktop → Settings → Resources → Virtual disk limit** (e.g. 96GB).

---

## Demo plan: showing the model is encrypted

### The problem with “just curl”

Attestation, KBS, and decrypt happen at **pod startup**. A single successful `POST /v1/generate` does not *look* dramatic. This repo deploys **three pods from the same image** so you can show **what breaks** and **what differs** before anyone sends a prompt.

### Three arms (same `IMAGE`, different runtime / env)

| Deployment | Route | Runtime | `DEMO_MODE` | What the audience sees |
|------------|-------|---------|-------------|-------------------------|
| **inference-confidential** | `inference-confidential` | `kata-remote` (CVM) | `confidential` | Pod **Ready**; logs: CDH REST → DEK → decrypt `model.pt.enc`; `/demo/info` shows `demo_runtime: confidential` |
| **inference-plaintext** | `inference-plaintext` | default (ordinary pod) | `plaintext` | Pod **Ready**; **no** KBS; loads `/app/plaintext/model.pt`; same API, proves the model works without CoCo |
| **inference-baseline-encrypted** | *(no route)* | default | `confidential` | Pod **CrashLoop**; KBS **resource policy** denies `sample` attester (no DEK); no Route to prompt |

**Same image** contains:

- `/app/encrypted/model.pt.enc` — what you ship to production (confidential path).
- `/app/plaintext/model.pt` — **demo control only**; confidential pods never read it.
- **DEK is not in the image** — only in KBS (`make local-register-dek` or operator registers from bundle).

The plaintext copy is intentional: it lets you say *“the model isn’t magic; the trust path is. Watch `/demo/info` and the failing pod.”*

### Why not only a normal container?

A normal pod with `DEMO_MODE=confidential` **fails** (baseline arm)—that is the proof that encryption matters. A normal pod with `DEMO_MODE=plaintext` **succeeds**—that is the apples-to-apples inference control. You need **both** plus the confidential pod.

---

## Presenting the demo (step-by-step)

Do this **after** `make e2e` or the quick-start steps. Allow ~10–15 minutes.

### 0. Set routes (optional)

```bash
export CONF_URL="https://$(oc get route inference-confidential -n confidential-inferencing -o jsonpath='{.spec.host}')"
export PLAIN_URL="https://$(oc get route inference-plaintext -n confidential-inferencing -o jsonpath='{.spec.host}')"
```

Or run the automated script: **`make demo`** (`scripts/demo-present.sh`).

---

### Step 1 — The image ships ciphertext, not the key (~2 min)

**On your laptop:**

```bash
make inspect-image    # default: quay.io/lgallett/confidential-inferencing-demo:latest
```

**Say:** “The registry image contains encrypted weights. The data encryption key never gets pushed with the image.”

**Expected output (abbreviated):**

```
/app/encrypted/model.pt.enc
/app/encrypted/manifest.json
/app/plaintext/model.pt          # demo control only
```

**Where things live:**

| Artifact | Location |
|----------|----------|
| Encrypted weights | Container image layer |
| DEK | KBS only (`default/confidential-inferencing-dek/dek`) |
| Plaintext weights (control) | Image path used only when `DEMO_MODE=plaintext` |

---

### Step 2 — Three pods, one image (~2 min)

```bash
oc get pods -n confidential-inferencing \
  -l 'demo-role in (confidential,plaintext-control,baseline-encrypted-fail)' \
  -o wide
```

**Say:** “Same image digest on all three. Different runtime class and environment.”

**Expected:**

| Pod | RUNTIME | STATUS |
|-----|---------|--------|
| `inference-confidential-…` | `kata-remote` | `Running` / Ready |
| `inference-plaintext-…` | *(empty)* | `Running` / Ready |
| `inference-baseline-encrypted-…` | *(empty)* | `CrashLoopBackOff` or not Ready |

---

### Step 3 — Baseline fails to unlock (~2 min)

```bash
oc logs -n confidential-inferencing deploy/inference-baseline-encrypted --tail=20
```

**Say:** “This pod tries the real confidential startup—KBS and decrypt—but it is **not** in a confidential VM. KBS policy rejects the **sample** attester, so it never gets the DEK. There is **no Route**—you cannot prompt it; show `oc logs` and pod status.”

**Expected:** `CrashLoopBackOff` and KBS/attestation errors in logs (not a running inference server).  
**Note:** If baseline is `Running`, the KBS resource policy is too loose (`count(input.submods) > 0`). Re-run `make relax-resource-policy-snp` and `make measure-attestation` — see **[docs/attestation-and-policy.md](docs/attestation-and-policy.md)** for the full matrix (`AzSnpVtpm` vs `sample`).

---

### Step 4 — Compare `/demo/info` (~3 min)

**Confidential (CVM):**

```bash
curl -sS "${CONF_URL}/demo/info" | jq .
```

**Expected (key fields):**

```json
{
  "demo_mode": "confidential",
  "demo_runtime": "confidential",
  "shipping_artifact": {
    "encrypted_present": true,
    "encrypted_size_bytes": 455067
  },
  "plaintext_control_baked_in_image": true,
  "decrypt_manifest": { "algorithm": "aes-256-gcm", "...": "..." }
}
```

**Plaintext control (ordinary pod):**

```bash
curl -sS "${PLAIN_URL}/demo/info" | jq .
```

**Expected:**

```json
{
  "demo_mode": "plaintext",
  "demo_runtime": "plaintext-control",
  "shipping_artifact": { "encrypted_present": true },
  "decrypt_manifest": {}
}
```

**Say:** “Confidential pod decrypted `model.pt.enc` after KBS. Plaintext pod skipped KBS and used the baked-in control copy—same HTTP API, different trust story.”

---

### Step 5 — Confidential startup logs (~2 min)

```bash
oc logs -n confidential-inferencing deploy/inference-confidential -c inference | head -30
```

**Say:** “This is the dramatic part—before any user prompt.”

**Expected log lines (order may vary):**

```
[entrypoint] DEMO_MODE=confidential Fetching DEK from KBS path=default/confidential-inferencing-dek/dek
[entrypoint] DEK retrieved (32 bytes)
[entrypoint] Decrypting model.pt.enc (AES-256-GCM)
[entrypoint] Plaintext weights exist only in memory/disk under /app/data (ephemeral)
```

**Where each step runs:**

| Step | Runs on |
|------|---------|
| KBS / RCAR / JWE | Guest agents + `kbs-client` inside **CVM**; KBS on cluster |
| AES decrypt | **CVM** container entrypoint |
| HTTP inference | **CVM** only |

---

### Step 6 — Same prompt, two working endpoints (~2 min)

```bash
BODY='{"prompt":"confidential","max_new_tokens":40}'

curl -sS -X POST "${CONF_URL}/v1/generate" -H 'Content-Type: application/json' -d "$BODY" | jq .
curl -sS -X POST "${PLAIN_URL}/v1/generate" -H 'Content-Type: application/json' -d "$BODY" | jq .
```

**Expected (similar on both; training may vary slightly):**

```json
{
  "prompt": "confidential",
  "completion": " inferencing runs inside a hardware trus",
  "full_text": "confidential inferencing runs inside a hardware trus"
}
```

**Say:** “Similar text proves the **same model**. Confidential path had to **unlock** weights first; plaintext path did not. Production would **not** ship `/app/plaintext`—only the encrypted artifact + KBS.”

---

### Step 7 — Close (~1 min)

| Question | Answer |
|----------|--------|
| Is the model encrypted at rest? | Yes — `model.pt.enc` in the image; DEK in KBS |
| Can a normal pod run it? | No — baseline arm fails |
| Does CoCo add value? | Confidential pod attests and decrypts inside CVM |
| Why HTTP after startup? | Trust bootstrapping once; inference is cheap |

---

## Diagram: demo arms

```
                    SAME CONTAINER IMAGE
                    ├─ /app/encrypted/model.pt.enc  ← production shipping
                    └─ /app/plaintext/model.pt      ← demo control only

  ┌─────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────────┐
  │ inference-confidential  │  │ inference-plaintext     │  │ inference-baseline-     │
  │ kata-remote (CVM)       │  │ default runtime         │  │ encrypted               │
  │ DEMO_MODE=confidential  │  │ DEMO_MODE=plaintext     │  │ DEMO_MODE=confidential  │
  │                         │  │                         │  │ default runtime         │
  │ KBS → DEK → decrypt     │  │ skip KBS, use plaintext │  │ KBS → FAIL              │
  │ ✅ Route + generate     │  │ ✅ Route + generate     │  │ ❌ CrashLoop            │
  └─────────────────────────┘  └─────────────────────────┘  └─────────────────────────┘
```

---

## Architecture (install time)

**Local profile:**

```
  Laptop                         One ARO cluster
  prepare / cosign / build       local-register-dek / local-register-policy
  local-deploy             ───►  3 demo deployments → local KBS route
```

**Remote KBS profile:**

```
  Model owner laptop             Operator ARO              Inference ARO
  export-operator-bundle   ──►  operator-cluster          remote-cluster
  (dek.bin, cosign.pub)          (DEK + policy on KBS)     (pods → remote KBS_URL)
                                 operator-export-kbs-endpoint
                                 (kbs.url, ca.pem, initdata.toml)
```

---

## Scripts

| Path | Purpose |
|------|---------|
| `config/*.env.example` | Copy to `*.env` for local / operator / remote profiles |
| `scripts/kbs/register-dek.sh` | DEK → KBS (local or operator target) |
| `scripts/kbs/register-policy.sh` | Cosign policy → KBS |
| `scripts/kbs/configure-kbs.sh` | `kbs.env` + `kbs-ca` ConfigMap (local or remote) |
| `scripts/kbs/export-operator-bundle.sh` | Handoff bundle for operator |
| `scripts/kbs/export-kbs-endpoint.sh` | Operator exports URL + CA for model owner |
| `scripts/kbs/apply-peer-pods-initdata.sh` | Peer-pods initdata for remote KBS |
| `scripts/kbs/relax-resource-policy-snp.sh` | SNP demo fix for KBS `PolicyDeny` after attest 200 |
| `scripts/kbs/sync-trustee-attestation.sh` | Re-run configure-trustee + reapply initdata |
| `scripts/deploy-demo.sh` | Three-arm demo |
| `scripts/prepare-model.sh`, `scripts/build-and-push.sh`, … | Laptop build pipeline |

Thin wrappers: `scripts/register-dek.sh`, `scripts/extract-kbs-config.sh` → `scripts/kbs/`.

## API

| Endpoint | Purpose |
|----------|---------|
| `GET /demo/info` | How this pod loaded the model (use in demo) |
| `GET /healthz`, `GET /readyz` | Ready after load |
| `POST /v1/generate` | `{"prompt":"confidential","max_new_tokens":40}` |

## Troubleshooting

**No `oc logs` on `inference` container** — normal while status is `CreateContainerError`; the container never started. Use `oc describe pod` events and Trustee logs instead.

**`register-policy` vs `register-dek`** — separate steps. Policy allows the signed image; DEK is a different KBS resource.

**Attestation OK but `PolicyDeny` (AMD SNP):** Trustee shows `Verifier/endorsement check passed. tee=AzSnpVtpm` and `POST /attest 200`, then `GET .../trustee-image-policy/policy` **401** `PolicyDeny`. The verify log uses the Rust `Tee` name; the JWT stores evidence under **`az-snp-vtpm`** in `ear.veraison.annotated-evidence`. Rego that checks `AzSnpVtpm` always denies even when verification passes.

```bash
make relax-resource-policy-snp
oc delete pod -n confidential-inferencing -l app=inference-confidential
```

Success: policy GET returns **200**. Then fix cosign if needed (next row).

**`sigstoreSigned` / image policy rejected** (after policy GET is 200): Attestation and KBS resource policy are OK; the **guest** (CDH / `containers/image`) still rejects the signature. **Cosign v3** stores signatures as OCI **bundle referrers** (`application/vnd.dev.sigstore.bundle.v0.3+json`), which CDH does not verify — you need a legacy **`.sig` tag** (`COSIGN_DOCKER_MEDIA_TYPES=1 cosign sign --new-bundle-format=false` on the image digest). `make fix-image-sign` does this and refreshes Trustee policy.

```bash
make fix-image-sign
# Confirm legacy tag exists:
skopeo list-tags docker://$IMAGE | grep '\\.sig'
```

This adds a legacy `.sig` tag, updates KBS policy for both `repo` and `repo:tag`, and restarts the confidential pod.

**RVPS / initdata drift** — if attest never succeeds or behavior is inconsistent after cluster rebuild:

```bash
make sync-trustee-attestation
```

**Image pull denied (OpenShift registry)** — `make register-policy` + cosign sign on laptop.

**`ProgressDeadlineExceeded` / confidential stuck in `ContainerCreating`:**  
Usually Azure peer-pod VM size or region — see **[coco-infra README: Azure region](../coco-infra/README.md#azure-region-location)**. Then:

```bash
oc describe pod -n confidential-inferencing -l app=inference-confidential | grep -A2 InvalidParameter
bash scripts/fix-peer-pods-azure.sh
oc delete pod -n confidential-inferencing -l app=inference-confidential
```

**Plaintext `CrashLoopBackOff` / `Permission denied` on `/app/data`:** OpenShift runs as a random UID. Rebuild/push image (uses `/tmp/inference-data`), then:

```bash
oc rollout restart deployment/inference-plaintext -n confidential-inferencing
```

**Baseline pod Running (unexpected)** — It should fail; if it is Ready, check `DEMO_MODE` and image tag.

**Plaintext route for production** — Do not; it exists only to contrast trust paths in demos.

**Image pull OK but confidential CrashLoop on DEK** — Rego and cosign can both be correct while runtime DEK still fails. The app container must fetch the DEK via **CDH REST** (`127.0.0.1:8006`), not `cdh.sock` or direct `kbs-client`. Run `cd policy-dry-run && make dry-run` to validate the repo stack offline; see [docs/attestation-and-policy.md](docs/attestation-and-policy.md).

## References

- [policy-dry-run/README.md](policy-dry-run/README.md) — offline Rego/cosign checks + first-time DEK path pitfalls
- [docs/attestation-and-policy.md](docs/attestation-and-policy.md) — three KBS touchpoints, Rego shape, live matrix
- [coco-infra README](../coco-infra/README.md) — ARO setup, **`LOCATION` / eastus vs eastus2**, peer pods
- [coco-infra primer](../coco-infra/docs/confidential-inferencing-primer.md)
- [KBS attestation protocol](https://github.com/confidential-containers/trustee/blob/main/kbs/docs/kbs_attestation_protocol.md)
