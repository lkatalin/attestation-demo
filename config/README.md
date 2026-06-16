# Deployment profiles

Two roles, two clusters (typical cross-cluster demo):

| Role | Cluster | What you run |
|------|---------|----------------|
| **Model owner** | Inference ARO (CoCo + peer pods) | `make laptop-prep`, `make remote-cluster` |
| **KBS operator** | Trustee/KBS ARO | `make operator-cluster` or [`kbs-tee-attestation/`](../kbs-tee-attestation/) |

Same machine, one cluster (lab):

| Profile | `make` targets |
|---------|----------------|
| **Local** | `make local-cluster` (KBS + inference on one `oc` login) |

## Files

| File | Use |
|------|-----|
| `local.env.example` | Copy to `local.env` — single-cluster demo |
| `inference-remote.env.example` | Copy to `inference-remote.env` — model owner, remote KBS |
| `operator.env.example` | Copy to `operator.env` — KBS host registers DEK + policy |
| `../docs/attestation-and-policy.md` | Attestation matrix, KBS Rego rules, `make measure-attestation` |

Load env files:

```bash
set -a && source config/local.env && set +a
make local-cluster
```

## Remote KBS flow (summary)

1. **Model owner:** `make export-operator-bundle` → share `artifacts/operator-bundle/` (DEK, cosign pub, policy JSON, image ref).
2. **Operator:** `oc login` their cluster → `make operator-cluster` (policy + DEK + `relax-resource-policy-snp` for SNP).
3. **Operator:** `make operator-export-kbs-endpoint` → share `kbs.url`, `kbs-ca.pem`, and **`initdata.toml`** (from their `coco-infra` Trustee setup).
4. **Model owner:** `oc login` inference cluster → set `KBS_URL`, `KBS_CA_FILE`, `INITDATA_PATH` → `make remote-cluster`.

The inference cluster **peer-pods `initdata` must match the operator’s KBS** (URL + CA + attestation policy). Use the operator’s `initdata.toml` when applying peer-pods (`make remote-apply-initdata`).
