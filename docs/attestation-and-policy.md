# Attestation requirements and KBS resource policy

This demo uses **one image** and **three deployments**. KBS must distinguish:

| Deployment | Runtime | Who attests for the DEK | Expected `tee` at KBS | Expected pod behavior |
|------------|---------|-------------------------|------------------------|------------------------|
| `inference-confidential` | `kata-remote` (peer pod / CVM) | **CDH REST API** (guest AA inside VM) | `AzSnpVtpm` | Running; DEK GET **200** |
| `inference-baseline-encrypted` | default (worker node) | `kbs-client` → **sample** fallback | `Sample` | CrashLoop; DEK GET **401 PolicyDeny** |
| `inference-plaintext` | default | *(no KBS)* | — | Running; no DEK fetch |

There is **no Route** on baseline — “prompt does nothing” is expected; show failure via `oc logs` and Trustee.

## Three KBS touchpoints in the guest (not one)

First-time setup often passes **image pull** attestation but fails **runtime DEK** unlock. These are separate paths:

| Touchpoint | When | Mechanism | Config |
|------------|------|-----------|--------|
| **Signed image pull** | Guest boot, before app container starts | CDH + Attestation Agent | `initdata.toml` → `cdh.toml`, `aa.toml` |
| **Runtime DEK** | App entrypoint at container start | CDH **REST API** in pod network namespace | `container/entrypoint.sh` |
| **Direct `kbs-client`** | Fallback only (baseline / broken CVM path) | App container calls KBS directly | Needs vTPM in container — **not available** in workload |

### Runtime DEK: REST API, not `cdh.sock`

CDH listens on `unix:///run/confidential-containers/cdh.sock` in the **guest sandbox** mount namespace. Workload containers in Kata/peer pods usually **cannot see** that socket.

CDH also exposes a REST API on **`http://127.0.0.1:8006/cdh/resource/{path}`**, which shares the **pod network namespace** and is reachable from the app container ([CoCo get-resource](https://confidentialcontainers.org/docs/features/get-resource/)).

The reference entrypoint order:

1. `curl http://127.0.0.1:8006/cdh/resource/default/confidential-inferencing-dek/dek`
2. `ttrpc-cdh-tool` via unix socket (fallback)
3. Read boot-prefetched file under `/run/confidential-containers/cdh/kbs/…` (often not visible)
4. `kbs-client` in entrypoint (baseline / non-CVM only → sample → deny)

**Do not** mount Kubernetes `hostPath` on `/run/confidential-containers` — it overlays the worker node’s empty directory and hides the guest CDH paths.

### Boot `[[credentials]]` in initdata (optional)

`cdh.toml` can prefetch the DEK at guest boot. On some platforms CDH starts before vTPM is ready → sample attestation → PolicyDeny. Runtime REST fetch after the guest is up is more reliable.

### OpenShift SCC

`kata-remote` pods use `sandboxed-containers-operator-scc` (`MustRunAsNonRoot`). Set `USER 1001` in the Dockerfile rather than relying on Deployment `runAsUser`.

## Policy input shape (Rego)

KBS evaluates **JWT attestation claims** (`input`) plus request metadata (`data.plugin`, `data.resource-path`). Trustee attestation logs show `tee=AzSnpVtpm` (Rust enum name); the EAR token stores platform evidence under the **serde rename** key `az-snp-vtpm` in annotated evidence (same as `kbs-types` / `transform_claims` in Trustee).

```json
{
  "plugin": "resource",
  "resource-path": ["default", "confidential-inferencing-dek", "dek"],
  "submods": {
    "cpu0": {
      "ear.veraison.annotated-evidence": {
        "az-snp-vtpm": { "measurement": "...", "tpm": { "pcr11": "..." } },
        "sample": { "productId": "", "svn": "" }
      },
      "ear.status": "affirming"
    }
  }
}
```

Rules in `policy/kbs-resource-policy-snp-demo.rego`:

- **Allow** only when `az-snp-vtpm` is present in `ear.veraison.annotated-evidence` (still SNP-only; not relaxed).
- **Deny** when only `sample` is present (baseline on the worker).

Do **not** use `allow if count(input.submods) > 0` — that allows baseline to decrypt.

Do **not** check `AzSnpVtpm` (PascalCase) in Rego — that key is never written to the token; you will see `tee=AzSnpVtpm` in verify logs and `PolicyDeny` on every resource GET.

## Gather measurements

```bash
make measure-attestation
```

This prints a table from cluster state, pod logs, and Trustee (`tee=` on verify, DEK GET status). Optional: build a probe image and run `scripts/kbs/probe-attestation-job.yaml`.

## Apply policy

```bash
make relax-resource-policy-snp   # installs policy/kbs-resource-policy-snp-demo.rego
oc delete pod -n confidential-inferencing -l 'demo-role in (confidential,baseline-encrypted-fail)'
```

## Expected Trustee lines (after probe / restart)

**Confidential (CVM):**

```
Verifier/endorsement check passed. tee=AzSnpVtpm
GET .../trustee-image-policy/policy HTTP/1.1" 200
GET .../confidential-inferencing-dek/dek HTTP/1.1" 200
```

(`tee=` is the verifier label; Rego must match claim key `az-snp-vtpm`.)

**Baseline (non-CVM):**

```
Verifier/endorsement check passed. tee=Sample
PolicyDeny
GET .../confidential-inferencing-dek/dek HTTP/1.1" 401
```

## Troubleshooting

| Observation | Cause | Action |
|-------------|-------|--------|
| Baseline `Running`, DEK in logs | Loose resource policy or old pod | `make relax-resource-policy-snp`; delete baseline pod |
| Image pull OK, DEK never fetched / `Waiting for CDH socket` → `kbs-client` → `Sample` | Workload used socket or direct kbs-client, not CDH REST | Use entrypoint with `fetch_dek_via_cdh_rest`; see [policy-dry-run/README.md](../policy-dry-run/README.md#runtime-dek-fetch-workload-container) |
| hostPath on `/run/confidential-containers` | Masks guest CDH with worker node dir | Remove hostPath from deployment |
| `runAsNonRoot and image will run as root` on kata-remote | Image USER unset | Add `USER 1001` to Dockerfile |
| Confidential `PolicyDeny`, `tee=Sample` on DEK | Direct `kbs-client` in app container (no vTPM) | Fix DEK path to CDH REST; do not expect entrypoint kbs-client on CVM |
| `tee=AzSnpVtpm` + `PolicyDeny` on resource GET | Rego checks wrong claim key (`AzSnpVtpm` vs `az-snp-vtpm`) | Re-apply `make relax-resource-policy-snp` (policy file uses `az-snp-vtpm`) |
| Image pull `sigstoreSigned` denied | Cosign v3 bundle vs CDH | `make fix-image-sign` (cosign v2 `.sig` tag) |

**Offline checks before deploy:** `cd policy-dry-run && make dry-run && make check-handoff`

The staged `kbs-client` from `ghcr.io/.../kbs-client-image` is built **without attester features** and always falls back to sample. It remains in the image as a **baseline fallback** only. Build with SNP attester if you need direct kbs-client testing:

```bash
make build-kbs-client   # uses local cargo if installed, else Docker (linux/amd64)
```
