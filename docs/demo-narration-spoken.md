# Confidential inferencing demo — spoken script (with commands)

Read the prose aloud. Run each command block when you reach that point in the story.

---

Most security stories are about one of two types of encryption.

**Encryption at rest:** data protected while sitting on disk.

**Encryption in transit:** data protected while moving across networks.

This is a story about a third type: **encryption in use**.

At some point, if we want to compute on data, the CPU needs access to plaintext. So while in use, data that might have been encrypted at rest or in transit is no longer encrypted.

That creates a trust problem.

Suppose we have two parties that want to work together:

- A **data owner** with sensitive data.
- A **model owner** with valuable IP.

The consumer wants to use the model without exposing their data. The model owner wants to serve the model without giving away the weights that define it.

One direct solution is **homomorphic encryption**—math on ciphertext. But the cost is still too high for most practical use, and repeated prompts can leak information even when encrypted.

The direction this demo takes is **Trusted Execution Environments**: a protected place where sensitive computation can happen.

---

## The vault analogy

Traditional cloud is a building with multiple tenants. Tenants can’t access each other’s units, but the building manager could.

A TEE is like a **vault inside one unit**. Modern CPUs (AMD SNP here) give us **confidential VMs** whose memory and boot state are protected and **measured**—plaintext for computation inside the vault, not to the landlord.

So the model owner can encrypt weights with a **DEK**, publish ciphertext in a container image, and **only release the DEK** if the model runs inside one of these vaults.

But if any process can say “trust me, I’m a vault,” the model is worthless. We need **attestation**: hardware-backed evidence.

Attestation is a series of locked doors—the more you prove, the more you may unlock.

---

## KBS and initdata

How does the CVM know **who** to talk to and **whether to trust them**?

**KBS** (Key Broker Service, behind Trustee) is that broker.

When the cluster launches a CVM, it uses **initdata**—an instruction sheet embedded at boot for:

- where KBS lives  
- which certificates to trust  
- how to verify container images  

On many confidential stacks, initdata is **cryptographically tied** to the launch report or vTPM measurements—change initdata, change the attestation fingerprint. **Open question on this ARO cluster:** we expected the same, but when we patched initdata in `peer-pods-cm` (and later via pod annotation), the SNP **`measurement` and `pcr11` in the JWT did not change**. New pods still attested the same hex as golden. Initdata clearly still **configures** the guest—KBS URL, cosign policy, agent settings—but the fields we pin in Act II track the **OSC pod VM image**, not every initdata edit from the API.

**Say:** “The initdata spec reads as if boot wiring and fingerprint move together. On **this** Azure peer-pod cluster, we haven’t seen that in the token yet—same pod VM build, same measurement, even when the ConfigMap initdata blob changed. That may be platform wiring, OSC version, or where the digest lands in evidence—we’re treating it as an open question, not something Trustee or Rego alone can fix.”

**Say:** “Initdata is still essential—it tells the guest where KBS lives and how to pull signed images. Our **DEK gate** keys off measurement and PCR11 as returned today, which here look like **vault build**, not initdata text.”

**Cluster ready (prologue):**

```bash
oc get ns confidential-inferencing 2>/dev/null || echo "no inference namespace yet"
oc get runtimeclass kata-remote
oc get deployment -n trustee-operator-system trustee-deployment
```

**One-time before any CVM boots** (so we can capture golden fingerprints later without extra reboots):

```bash
make enable-peer-pods-guest-rest-api
```

---

## Attestation: two doors, same hardware stamp

When Kubernetes schedules a CVM, **before the application starts**, the guest asks AMD SNP and the vTPM for a **hardware report**: measurements of how the VM booted, signed so it can’t be forged. KBS verifies the signature and endorsements.

But KBS isn’t only attestation—it **gates access** with **policies**. Attestation passing is step one; **what you’re allowed to fetch** is step two.

Trustee verifies the hardware report and endorsement (RVPS) first. Then, on each resource request, a separate policy decides allow or deny. Attest 200 on the baseline pod only means “KBS accepted a sample report”—not “this guest gets the DEK.”

**Door 1 — image pull (guest boot)**  
The VM attests, then asks: “May I pull **this signed container image**?”  
Policy: cosign / Sigstore trust—the image must be signed by our key.

**Door 2 — DEK release (app startup)**  
Same CVM, **new** request: “May I read the **decryption key**?”  
Policy: resource Rego—staging says “real SNP guest”; production adds **pinned measurement + PCR11**.

Same hardware report both times; **different resource, different rulebook**.

**Say:** “Pinning is **not** a per-request firewall on inference traffic. It runs when the guest **fetches the DEK** from KBS—usually once at container startup. After that, decrypted weights live in the vault’s memory. Changing Rego on KBS does **not** restart pods and does **not** pull keys back from pods that already decrypted.”

**Say:** “**Signed image (Door 1)** stops the attack where someone runs the right vault with the **wrong container**—CDH won’t pull an unsigned or untrusted image. **Pinned vault build (Door 2)** stops ‘any SNP box in the cloud.’ You need both.”

---

## Build secrets on the laptop

We create a tiny model, encrypt it, and keep the DEK off the cluster until KBS releases it.

```bash
make laptop-prep
ls -la artifacts/dek.bin artifacts/model.pt.enc artifacts/manifest.json
cosign verify --key artifacts/cosign.pub "$IMAGE" 2>&1 | head -2
```

The DEK never goes in git. The image ships ciphertext (plus a plaintext copy for the control arm only).

---

## Register with KBS and staging policy

We register the DEK as a KBS secret, the cosign public key, and the Sigstore verification JSON for image pull.

```bash
make local-register-dek
make local-register-policy
```

Show the staging **DEK rule** we’ll apply—real SNP only, not “any attestation”:

```bash
cat policy/kbs-resource-policy-snp-demo.rego
make dry-run-policy
make relax-resource-policy-snp
make show-live-resource-policy
```

Test on the laptop first, then patch KBS—same file we dry-ran, now live.

---

## Act I — three pods, one image

We deploy **three pods** from the same signed image:

| Pod | Runtime | Image pull | DEK |
|-----|---------|------------|-----|
| **Confidential** | CVM (`kata-remote`) | Guest attestation + cosign | SNP → allow (staging) |
| **Baseline encrypted** | Ordinary worker | **Kubelet** (no CVM attestation path) | `sample` attester → deny |
| **Plaintext** | Worker | Normal pull | Never asks KBS |

```bash
make act-i-deploy
```

First confidential CVM boot: often **15–30 minutes**. Plaintext is fast; baseline may look **Running** but not **Ready**.

**Say:** “The baseline encrypted pod pulls the image because **normal pods aren’t on the guest attestation path**—kubelet pulls from the registry like any container. It still can’t decrypt; when the entrypoint asks KBS for the DEK, it only has a software **sample** attester, not real SNP hardware.”

```bash
oc get pods -n confidential-inferencing \
  -l 'demo-role in (confidential,plaintext-control,baseline-encrypted-fail)' \
  -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.demo-role,READY:.status.containerStatuses[0].ready

make measure-attestation
```

Prompt all three arms—same in-domain prompt, different outcomes:

```bash
export PROMPT="encrypted model weights stay ciphertext until"
make demo-prompt
```

Plaintext and confidential answer; baseline does not serve inference.

**Trustee logs**—confidential passed attestation and received the DEK:

```bash
oc logs -n trustee-operator-system deployment/trustee-deployment --tail=80 \
  | grep -E 'tee=|confidential-inferencing-dek|PolicyDeny' | tail -20
```

**Say:** “Under staging, that basically means **any genuine SNP CVM** could get the DEK—not just *this* vault build. Still, Act I shows what we needed first: **hardware class**—only a real confidential VM on AMD SNP can pass; an ordinary pod on the cluster worker cannot. And now in Act II we tighten to **hardware instance**—only *this* vault fingerprint from our golden boot—while cosign at Door 1 still controls *which signed image* runs inside.”
 
**Capture golden fingerprint** (staging artifact—like an AMI ID):

```bash
make capture-golden-claims
jq . policy-dry-run/captured/cvm-pins-golden.json
```

---

## Act II — pin production policy, restart golden

In production we’d run that first good boot in **staging**, capture **measurement + PCR11**, pin them in Rego, then promote to prod KBS.

```bash
make promote-production-policy
```

**Say:** “Staging only checked `az-snp-vtpm` exists. Production adds **exact hex** from our golden boot. Image pull policy didn’t change—**only the DEK gate** tightened.”

**Say:** “What did we pin? Not the inference container image—the **vault shell**. Think **AMI ID for the CVM**, not the app inside it. Cosign already bound the **app image** at Door 1. Every pod that boots the **same** OpenShift Sandboxed Containers pod VM reports the **same** measurement and PCR11—another replica, a new Deployment, a recreated pod: **same hex**, as long as the vault build didn’t change.”

**Say:** “When does KBS check the pin? Only when the guest **asks for the DEK** at startup—not on every inference request. If you change Rego on KBS, **already-running** pods do **not** restart and do **not** give the key back; a pod that **already fetched the DEK** keeps serving from memory until something **restarts** it. That’s why Act II **deletes and recreates** golden: prove a **new** boot still earns the key under the pinned rule.”

**Say:** “**Scale-out with correct pins is supposed to work.** Replica two, three, ten—each new CVM attests the same vault build, each one passes the DEK gate, each one decrypts. That’s normal production traffic growth, not a policy failure.”

**Say:** “**Scale-out fails** when the **vault build** and **Rego pins** disagree—usually after an **OSC / pod VM upgrade**: new CVMs report a **new** hex, KBS still has the **old** pin, fresh DEK fetch gets **PolicyDeny**. Fix: capture the new fingerprint, allow **both** pins during rollout, restart the fleet, drop the old pin.”

```bash
make demo-act-ii
```

Golden pod re-attests, DEK GET **200**, inference still works. Baseline still denied.

```bash
make show-live-resource-policy | grep -E 'measurement|pcr11'
jq -r '.measurement,.pcr11' policy-dry-run/captured/cvm-pins-golden.json
```

**Say:** “Live Rego and our captured golden file should show the **same** measurement and PCR11—that’s the binding we promoted.”

---

## Act III — upgrade drill: stale pin vs fresh boot

**Say:** “Step back for a second. In Act II we pinned the **measurement**—think of it as the **vault fingerprint**: a hardware-backed ID for *this* confidential VM build, like an AMI ID for the CVM shell.”

**Say:** “**Initdata** is the boot instruction sheet—where KBS lives, which certificate to trust, which cosign policy governs image pull. On many platforms, initdata is **part of** that fingerprint: change the instruction sheet, and the attestation report changes too. Different initdata → different measurement → KBS could deny the DEK until Rego is updated. That’s the story the initdata spec is written for.”

**Say:** “**Open question on this ARO cluster:** we tried it. We changed initdata in the API—ConfigMap, then pod annotation—and booted new CVMs. The **measurement in the JWT stayed the same.** Initdata still **wired** the guest correctly, but it did **not** move the hex we pin. So Act III doesn’t demo ‘wrong initdata → deny’ here. Instead we show the failure mode we **do** hit in production: **Rego still pins yesterday’s fingerprint** after the **pod VM image** upgrades underneath you.”

| Platform | Does initdata change the fingerprint we pin? |
|----------|---------------------------------------------|
| **Azure peer pods (this demo)** | **Not in practice** for cluster ConfigMap edits we tested—the JWT `measurement` tracks the **pod VM image**. Initdata still matters at **runtime** (Door 1 cosign, KBS URL). |
| **AMD SNP / Intel TDX on bare metal** | **Often yes**—initdata can be bound into the   launch report (e.g. HOSTDATA / guest config), so different initdata → different attestation. |
| **IBM Z / LinuxONE peer pods + CoCo** | **Often yes**—initdata is part of the measured guest state per OSC confidential-containers docs. |

**Say:** “So on **this** cluster, scaling replicas doesn’t change the hex—but an **OSC upgrade** can, because the **pod VM image** changed. That’s the real upgrade story: new vault build, old Rego pin, **new** pods fail until you dual-pin and roll.”

**Say:** “We can’t demo ‘edit initdata in the API → new hex’ live here. Act III shows what **does** break fleets: **Rego still pins yesterday’s measurement.** We apply a deliberately wrong hex on KBS and scale **one new replica**. It boots, attests for real, **PolicyDeny** on DEK GET. The **already-running** golden pod from Act II keeps answering—it **already holds the DEK** and doesn’t ask KBS again on every `/demo/info` call.”

**Say:** “That split confuses people: **policy change ≠ pod restart.** Wrong Rego blocks **new** boots immediately; **existing** pods keep serving until restarted. Production avoids the cliff with a **dual-pin window**—allow old **and** new hex while you roll the fleet—then remove the old pin.”

```bash
make show-live-resource-policy | grep -E 'measurement|pcr11'
make demo-act-iii
```

**Say:** “Watch the **new** replica—not golden. It does real SNP attestation, then **PolicyDeny** on DEK GET—logs stop before `Decrypting model.pt.enc`. Trustee shows `401` on the resource path. Golden route still returns `model_loaded: true` because that pod **already completed startup** under the correct pins.”

Compare stale pin vs golden capture:

```bash
grep 'measurement' policy/kbs-resource-policy-snp-act-iii-stale.rego | tail -1
jq -r '.measurement' policy-dry-run/captured/cvm-pins-golden.json
oc get pods -n confidential-inferencing -l demo-role=confidential \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready
oc logs -n trustee-operator-system deployment/trustee-deployment --since=15m \
  | grep -E 'confidential-inferencing-dek|PolicyDeny' | tail -10
```

```bash
make demo-act-iii-cleanup
```

**Say:** “Cleanup restores Act II pins and scales back. In production after a **pod VM upgrade**: capture the new hex, add it beside the old pin in Rego, **restart** workloads so every pod re-attests, then remove the old pin.”

**Say:** “Remember the three beats: **scale-out** with matching pins—fine. **New vault build + old pin**—new pods fail. **Rego change on a pod that already has the DEK**—that pod keeps serving until **you** restart it.”

-