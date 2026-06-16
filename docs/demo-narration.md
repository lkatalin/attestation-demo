# Confidential inferencing demo — spoken script

Read the prose aloud. Run each `make` target (or command) right after its block. Target descriptions are for you—not necessarily read verbatim.

---

## Prologue — blank cluster

We start on a fresh ARO cluster with Confidential Containers already installed—the key broker (KBS), Trustee, and peer pods—but no inference workloads yet. Nothing sensitive is in git.

Confirm the cluster is ready (no inference namespace yet, kata-remote exists, Trustee up):

```bash
oc get ns confidential-inferencing 2>/dev/null || echo "no inference namespace yet"
oc get runtimeclass kata-remote
oc get deployment -n trustee-operator-system trustee-deployment
```

**`make enable-peer-pods-guest-rest-api`** — Run once before any confidential VM boots. At a high level, this turns on guest attestation export for the whole demo so we can capture golden fingerprints later without rebooting workloads. Technically, it patches kata-oc workers’ remote `configuration.toml` to allow `kernel_params` and sets `agent.guest_components_rest_api=all`, exposing `/aa/token` and CDH REST on `127.0.0.1` inside each new CVM netns—not on the cluster network.

```bash
make enable-peer-pods-guest-rest-api
```

**Say:** “We flip this switch up front. Attestation and KBS policy are unchanged; in hardened prod you might narrow the API after CI capture.”

---

## Build the secret and the image

Everything sensitive is created on the laptop first: train the model, random DEK, encrypt weights, sign the image. A plaintext copy in the image is demo control only.

**`make laptop-prep`** — Prepares all laptop artifacts in one step. Runs `prepare-model.sh` (train + encrypt + manifest), `setup-cosign.sh` (keypair in `artifacts/`), and `build-and-push.sh` (amd64 image push + legacy `.sig`).

```bash
make laptop-prep
ls -la artifacts/dek.bin artifacts/model.pt.enc artifacts/manifest.json
cosign verify --key artifacts/cosign.pub "$IMAGE" 2>&1 | head -2
```

**Say:** “The DEK never goes in git. Peer pods verify cosign at boot before our container starts.”

---

## Register in KBS and deploy

Log into the cluster. Register the DEK and image-trust rules, then build the release rule step by step.

**`make local-register-dek`** — Registers the model decryption key with KBS. Creates the `confidential-inferencing-dek` secret in `trustee-operator-system`, adds it to `kbsconfig` `kbsSecretResources`, and restarts Trustee.

```bash
make local-register-dek
```

**`make local-register-policy`** — Registers cosign trust for image pull. Uploads the public key and Sigstore verification JSON (`confidential-inferencing-signature`, `trustee-image-policy`) to KBS secrets and kbsconfig.

```bash
make local-register-policy
oc get kbsconfig trusteeconfig-kbs-config -n trustee-operator-system \
  -o jsonpath='{.spec.kbsSecretResources}{"\n"}' | tr ' ' '\n' \
  | grep -E 'confidential-inferencing-dek|confidential-inferencing-signature|trustee-image-policy'
```

**Say:** “Step one: name the secret and the signed image. Still no ‘who may decrypt’ rule—that comes next.”

### Policy — building trust rules from nothing

**Say:** “We build the rule step by step—test on the laptop, then apply—same as production.”

**Two questions KBS always asks:** Was the **container image signed**? (boot / CDH.) May **this guest read the DEK**? (after attestation.) Same signed image on a worker must fail the second—that is the demo.

**What a fingerprint is:** Azure records a **boot fingerprint** of the CVM shell (not your Python app). KBS compares it before releasing secrets.

#### Step 0 — Out-of-box rule

```bash
head -25 policy/operator-default-resource-policy.rego
```

**Say:** “Fresh Trustee often shows `tee=AzSnpVtpm` + `attest 200` but `PolicyDeny` on the key—the generic rule does not match our platform yet.”

#### Step 2 — Write the staging rule (disk only)

```bash
cat policy/kbs-resource-policy-snp-demo.rego
```

**Say:** “Real SNP only—token key `az-snp-vtpm`, not log label `AzSnpVtpm`.”

#### Step 3 — Test on the laptop

**`make dry-run-policy`** — Offline spell-check for resource Rego and image policy. Runs `policy-dry-run/dry-run.sh` with synthetic SNP and sample fixtures through OPA.

```bash
make dry-run-policy
```

**`make check-handoff`** — Validates KBS URL, CA, and initdata alignment before deploy. Runs `policy-dry-run/check-handoff.sh` against the operator bundle.

```bash
make check-handoff
```

**Say:** “Should SNP pass and sample fail? Do URLs in initdata match KBS?”

#### Step 4 — Apply staging rule (Act I policy)

**`make relax-resource-policy-snp`** — Applies the wide demo Rego to KBS. Patches `trusteeconfig-resource-policy` with `kbs-resource-policy-snp-demo.rego`, restarts Trustee, and recycles confidential + baseline pods.

```bash
make relax-resource-policy-snp
make show-live-resource-policy
```

**Say:** “Any real SNP guest may read the key; baseline `sample` attester cannot. Staging shape—not production pins.”

#### Step 5 — Production shape (preview)

```bash
head -30 policy-dry-run/examples/kbs-resource-policy-snp-measurements.rego
```

**Say:** “Act I records golden pins; Act II promotes pinned Rego like this template.”

---

## Staging vs production

| Phase | Demo act | Policy | Goal |
|-------|----------|--------|------|
| **Staging** | Act I | Wide SNP (`relax-resource-policy-snp`) | Attest, DEK, decrypt, infer |
| **Golden record** | End Act I | *(artifact)* | `measurement` + `pcr11` on disk |
| **Production** | Act II | Pinned Rego + golden re-boot | Re-attest under pins |
| **Upgrade drill** | Act III | Same Rego, wrong initdata | New replica → PolicyDeny |

**Say:** “Stage first, pin second, drill third. Act II restarts golden—warm memory is not proof.”

Full reference: **`docs/production-attestation-policy.md`**, **`policy-dry-run/README.md`**.

---

## Act I — Staging: wide rule, prove the path, record golden pins

**Say:** “**Act I is staging.** Wide SNP rule; no fingerprint pin yet.”

**`make act-i-deploy`** — Aligns RVPS/initdata to this cluster’s peer-pod VM image, fixes Azure region/VM size, and deploys all three demo arms. Runs `sync-trustee-attestation.sh`, `fix-peer-pods-azure.sh`, and `deploy-demo.sh`.

```bash
make act-i-deploy
```

**`make measure-attestation`** — Prints who got the DEK vs PolicyDeny. Scrapes Trustee logs and pod status for `tee=AzSnpVtpm` vs `tee=Sample`.

```bash
make measure-attestation
```

**Say:** “Confidential: `tee=AzSnpVtpm` + DEK **200**. Baseline: `tee=Sample` + **PolicyDeny**. Staging gate passed.”

First confidential CVM boot: 15–30+ min. Plaintext is fast; baseline stays Running-not-Ready.

---

## Three pods — same image, different trust paths

**Confidential** — CVM on Azure: attest → DEK → decrypt → infer.

**Plaintext** — Worker, no KBS: plaintext weights in image.

**Baseline encrypted** — Worker, encrypted startup, no hardware proof: KBS denies DEK; Running but not Ready, no route.

```bash
oc get pods -n confidential-inferencing \
  -l 'demo-role in (confidential,plaintext-control,baseline-encrypted-fail)' \
  -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.demo-role,READY:.status.containerStatuses[0].ready
```

---

## Live demo — Act I (prompt each arm)

**`make demo-prompt`** — Prompts all three arms over HTTP (or port-forward for baseline). Runs `scripts/demo-prompt.sh`: routes, `/demo/info`, generate on confidential + plaintext, baseline failure path.

```bash
export PROMPT="encrypted model weights stay ciphertext until"
make demo-prompt
```

**Say:** “Same prompt, three outcomes. Only confidential earned decrypt under the **staging** rule.”

Or use **`make demo`** for a longer scripted walkthrough (`demo-present.sh`: inspect image, pod matrix, prompts, Trustee grep).

```bash
make demo
```

### Capture golden pins (end of Act I)

**Say:** “Record the launch fingerprint as a release artifact—like an AMI ID—before Act II pins production Rego.”

**`make capture-golden-claims`** — Spins a disposable `attest-probe` kata-remote pod (same signed image + cluster initdata), curls `/aa/token` inside the CVM, and writes `policy-dry-run/captured/cvm-pins-golden.json` plus claims fixtures. First probe boot: 15–30+ min. Rehearsal fallback: pre-saved pins file.

```bash
make capture-golden-claims
jq . policy-dry-run/captured/cvm-pins-golden.json
```

**Say:** “Golden fingerprint on disk. Act II generates pinned Rego from this file.”

---

## Act II — Production: promote pinned policy to KBS

**Say:** “SNP alone is not enough—the guest must match **this** measurement and PCR11. Then we restart golden so it re-attests under the new rule.”

**`make promote-production-policy`** — Full Act II policy promote. Generates `kbs-resource-policy-snp-production.rego` from golden pins, prints staging vs production diff, runs `dry-run-measurements` + `opa check`, patches KBS, restarts Trustee, and prints live ConfigMap Rego.

```bash
make promote-production-policy
```

**Say:** “Staging only checks `az-snp-vtpm` exists. Production adds exact measurement + PCR11 hex and EAR vector guards.”

If capture was skipped: `make capture-golden-claims` first. HTTP 404 on `/aa/token`: re-run prologue `make enable-peer-pods-guest-rest-api`.

**`make demo-act-ii`** — Production gate after policy apply. Shows policy diff + live Rego, deletes golden pod, waits for Ready, greps DEK success in pod and Trustee logs, runs `demo-prompt` with `DEMO_ACT=ii`.

```bash
make demo-act-ii
```

**Say:** “Fresh boot under **production** pins—still decrypts. Baseline still cannot. Act III tests a **new** VM next.”

---

## Act III — Upgrade drill: mismatched CVM denied

**Say:** “Same Rego from Act II. A **new** replica with changed initdata gets real SNP but wrong fingerprint → PolicyDeny. Golden pod stays running.”

```bash
make show-live-resource-policy | grep -E 'measurement|pcr11'
```

**`make demo-act-iii`** — Upgrade drill without touching golden. Runs `SKIP_POD_RESTART=1 sync-trustee-attestation` (new initdata for future CVMs only), scales confidential to 2, shows mismatch pod logs + Trustee PolicyDeny, curls golden route still serving.

```bash
make demo-act-iii
```

**Say:** “Real upgrades use old ∪ new pins during rollout—we skip that so the deny is visible.”

**`make demo-act-iii-cleanup`** — Removes the second replica and scales back to 1. Deletes the newest confidential pod and `oc scale … --replicas=1`.

```bash
make demo-act-iii-cleanup
```

Reset to staging rule: **`make relax-resource-policy-snp`**.

---

## Why attestation is hard here

Four checks, not one: **signed image pull** (CDH + cosign), **hardware attest** (`tee=AzSnpVtpm`), **resource Rego** (`az-snp-vtpm` + pins), **platform glue** (region, initdata, kata-remote).

```bash
oc logs -n trustee-operator-system deployment/trustee-deployment --tail=60 \
  | grep -E 'trustee-image-policy|tee=|confidential-inferencing-dek|PolicyDeny'
oc logs -n confidential-inferencing deploy/inference-confidential --tail=30 \
  | grep -E 'CDH REST|DEK fetched|Decrypting'
```

**Say:** “If attest succeeds but the key is denied, check **which ladder step**—not whether the pod is broken.”

---

## Closing

**Say:** “We staged, captured golden pins, promoted pinned Rego, and drilled a mismatch deny—dry-run on the laptop every time.”

```bash
make -C policy-dry-run production-strict
```

**Quick reference — make targets by act**

| Act | Targets |
|-----|---------|
| Prologue | `enable-peer-pods-guest-rest-api` |
| Laptop | `laptop-prep` |
| KBS register | `local-register-dek`, `local-register-policy`, `relax-resource-policy-snp` |
| Policy test | `dry-run-policy`, `check-handoff` |
| Act I | `act-i-deploy`, `measure-attestation`, `demo-prompt` or `demo`, `capture-golden-claims` |
| Act II | `promote-production-policy`, `demo-act-ii` |
| Act III | `demo-act-iii`, `demo-act-iii-cleanup` |
| Show policy | `show-policy-diff`, `show-live-resource-policy` |

One-shot local rehearsal (after laptop prep + oc login): **`make local-cluster`** runs register, staging policy, peer-pod prep, deploy, and `demo`.
