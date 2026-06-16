# Demo UI — live Acts I–III topology

Dark-themed live dashboard that **builds itself as you run the demo**. It watches the OpenShift cluster (pods + Trustee logs) over WebSocket — it does **not** reconstruct history from old logs if you open it after the fact.

## What you see

| Element | Interaction |
|---------|-------------|
| **KBS / Trustee** | Click → resource Rego, image policy JSON, KBS secrets |
| **CVM pods** | Click → cluster `initdata` from `peer-pods-cm` |
| **Neon paths** | Two gate bundles per CVM: dashed violet attest + solid policy path (image cyan, DEK lime) |
| **Path hover** | Policy name + pass/deny |
| **Path click** | Trustee log excerpt, trigger request, deny reason |
| **Prompt panel** | POST to confidential route (default demo prompt) |
| **Act badge** | Inferred from live Rego + pod count (I / II / III) |

## Prerequisites

- `oc login` to the demo cluster
- Python 3.10+
- Node 18+ (to build the frontend once)

## Quick start

```bash
# Terminal 1 — build UI (once) and start server
cd demo-ui
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
npm install && npm run build
python run.py
```

Open **http://127.0.0.1:8765** before running `make act-i-deploy`, then run the demo targets in another terminal. Events stream in as pods boot and Trustee logs attest/policy lines.

### Development (hot reload frontend)

```bash
# Terminal 1
cd demo-ui && source .venv/bin/activate && python run.py

# Terminal 2
cd demo-ui && npm run dev   # http://localhost:5173 proxies API/WS
```

### From repo root

```bash
make demo-ui          # build + serve
make demo-ui-dev      # backend only (run npm run dev separately)
```

## Environment

| Variable | Default |
|----------|---------|
| `DEMO_UI_HOST` | `127.0.0.1` |
| `DEMO_UI_PORT` | `8765` |
| `DEMO_NAMESPACE` | `confidential-inferencing` |
| `TRUSTEE_NS` | `trustee-operator-system` |
| `DEMO_PROMPT` | `encrypted model weights stay ciphertext until` |

## How attestation paths are correlated

Trustee logs do not include pod names. The UI uses:

1. **tee type** — `AzSnpVtpm` → confidential CVM; `Sample` → baseline
2. **Boot order** — newest unattributed confidential pod for SNP flows
3. **Log context** — rolling window of Trustee lines as the “attestation report”

For JWT claim hex (golden pins), use `make capture-golden-claims` — the UI focuses on **live** Trustee traffic during presentation.

## Act detection (heuristic)

- **Act I** — resource policy loaded, no measurement pins
- **Act II** — Rego contains `measurement` + `pcr11`
- **Act III** — two confidential pods (scale-out drill)
