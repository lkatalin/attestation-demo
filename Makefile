# Confidential inferencing demo
# Profiles: local (one cluster) | remote (inference here, KBS elsewhere)
# See config/README.md

.PHONY: help prepare setup-cosign build push laptop-prep inspect-image smoke demo fix-peer-pods
.PHONY: export-operator-bundle
.PHONY: local-register-dek local-register-policy local-configure-kbs local-deploy local-cluster
.PHONY: operator-register-dek operator-register-policy operator-export-kbs-endpoint operator-cluster
.PHONY: remote-configure-kbs remote-apply-initdata remote-deploy remote-cluster
.PHONY: sync-trustee-attestation relax-resource-policy-snp apply-production-resource-policy \
	bootstrap-production-policy fix-image-sign build-kbs-client measure-attestation dry-run-policy \
	capture-golden-claims capture-golden-via-probe enable-peer-pods-guest-rest-api \
	show-policy-diff show-live-resource-policy promote-production-policy check-handoff demo-prompt act-i-deploy
.PHONY: register-dek register-policy cluster deploy deploy-demo e2e

export ARTIFACTS ?= $(CURDIR)/artifacts
export IMAGE ?= quay.io/lgallett/confidential-inferencing-demo:latest
export OPERATOR_BUNDLE ?= $(ARTIFACTS)/operator-bundle
export PINS ?= policy-dry-run/captured/cvm-pins-golden.json

help:
	@echo "Laptop (no cluster):"
	@echo "  make laptop-prep          prepare + cosign + build"
	@echo "  make export-operator-bundle   zip handoff for KBS operator"
	@echo ""
	@echo "Local profile (one ARO, KBS + inference):"
	@echo "  make local-cluster        DEK + policy + peer-pod prep + deploy + demo"
	@echo "  make relax-resource-policy-snp   demo Rego only (not production)"
	@echo "  make promote-production-policy   Act II: generate + show diff + apply pinned Rego"
	@echo "  make show-policy-diff / show-live-resource-policy"
	@echo "  make bootstrap-production-policy  RVPS sync + capture + apply (needs cvm pins)"
	@echo "  make measure-attestation         print attestation / DEK behavior matrix"
	@echo "  make dry-run-policy              offline Rego + image policy checks (policy-dry-run/)"
	@echo "  make demo-act-ii                 Act II: restart golden pod + re-attest under pins"
	@echo "  make demo-act-iii                Act III: scale mismatch replica → PolicyDeny"
	@echo "  make demo-act-iii-cleanup        remove Act III second replica"
	@echo "  make capture-golden-claims            attest-probe → cvm-pins-golden.json"
	@echo "  make capture-golden-from-pod          legacy (port-forward; unreliable on peer pods)"
	@echo "  make build-kbs-client            SNP kbs-client (Docker if cargo missing; needs ../trustee)"
	@echo "  make local-register-dek / local-register-policy / local-deploy"
	@echo ""
	@echo "Operator profile (their ARO — oc login to KBS cluster):"
	@echo "  make operator-cluster     register DEK + policy from bundle"
	@echo "  make operator-export-kbs-endpoint   write kbs.url + kbs-ca.pem for model owner"
	@echo ""
	@echo "Remote profile (inference cluster — oc login here):"
	@echo "  source config/inference-remote.env"
	@echo "  make remote-cluster       initdata + peer-pod prep + deploy + demo"
	@echo ""
	@echo "Legacy aliases: register-dek, register-policy, cluster, deploy, e2e"

# --- Laptop ---
prepare:
	bash scripts/prepare-model.sh

train: prepare

setup-cosign:
	bash scripts/setup-cosign.sh

build:
	bash scripts/build-and-push.sh

push: build

laptop-prep: prepare setup-cosign build

export-operator-bundle:
	bash scripts/kbs/export-operator-bundle.sh

# --- Local (KBS on same cluster as inference) ---
local-register-dek:
	bash scripts/kbs/register-dek.sh

local-register-policy:
	bash scripts/kbs/register-policy.sh

local-configure-kbs:
	KBS_MODE=local bash scripts/kbs/configure-kbs.sh

local-deploy: local-configure-kbs
	KBS_MODE=local bash scripts/deploy-demo.sh

local-cluster: local-register-dek local-register-policy relax-resource-policy-snp fix-peer-pods enable-peer-pods-guest-rest-api local-deploy demo

# --- Operator (remote KBS host) ---
operator-register-dek:
	DEK_FILE=$(if $(DEK_FILE),$(DEK_FILE),$(OPERATOR_BUNDLE)/dek.bin) bash scripts/kbs/register-dek.sh

operator-register-policy:
	COSIGN_PUB=$(if $(COSIGN_PUB),$(COSIGN_PUB),$(OPERATOR_BUNDLE)/cosign.pub) bash scripts/kbs/register-policy.sh

operator-export-kbs-endpoint:
	bash scripts/kbs/export-kbs-endpoint.sh

operator-cluster: operator-register-policy operator-register-dek relax-resource-policy-snp operator-export-kbs-endpoint

# --- Remote inference (model on your cluster, KBS elsewhere) ---
remote-configure-kbs:
	KBS_MODE=remote bash scripts/kbs/configure-kbs.sh

remote-apply-initdata:
	bash scripts/kbs/apply-peer-pods-initdata.sh

remote-deploy: remote-configure-kbs
	KBS_MODE=remote DEPLOY_PROFILE=remote bash scripts/deploy-demo.sh

remote-cluster: remote-apply-initdata fix-peer-pods enable-peer-pods-guest-rest-api remote-deploy demo

# KBS resource policy: allow SNP TEE, deny sample attester (baseline must not get DEK)
apply-initdata-dek-via-cdh:
	bash scripts/kbs/apply-initdata-dek-via-cdh.sh

rollout-dek-via-cdh: apply-initdata-dek-via-cdh
	bash scripts/kbs/configure-kbs.sh
	bash scripts/kbs/rollout-confidential-dek-via-cdh.sh

sync-trustee-attestation:
	bash scripts/kbs/sync-trustee-attestation.sh

relax-resource-policy-snp:
	bash scripts/kbs/relax-resource-policy-snp.sh

apply-production-resource-policy:
	bash scripts/kbs/apply-production-resource-policy.sh

bootstrap-production-policy:
	bash scripts/kbs/bootstrap-production-policy.sh

generate-production-policy:
	bash scripts/kbs/generate-production-policy.sh --pins $(PINS)

show-policy-diff:
	@echo "=== Staging (demo) ==="
	@cat policy/kbs-resource-policy-snp-demo.rego
	@echo ""
	@echo "=== Production (generated) ==="
	@test -f policy/kbs-resource-policy-snp-production.rego || (echo "Run make generate-production-policy first" >&2; exit 1)
	@cat policy/kbs-resource-policy-snp-production.rego
	@echo ""
	@echo "=== Diff (staging → production) ==="
	@diff -u policy/kbs-resource-policy-snp-demo.rego policy/kbs-resource-policy-snp-production.rego | head -60 || true

show-live-resource-policy:
	@oc get configmap trusteeconfig-resource-policy -n trustee-operator-system \
	  -o jsonpath='{.data.policy\.rego}'

promote-production-policy: generate-production-policy show-policy-diff apply-production-resource-policy show-live-resource-policy

check-handoff:
	$(MAKE) -C policy-dry-run check-handoff

demo-prompt:
	bash scripts/demo-prompt.sh

act-i-deploy: sync-trustee-attestation fix-peer-pods local-deploy

build-kbs-client:
	bash scripts/build-kbs-client.sh

measure-attestation:
	bash scripts/kbs/measure-attestation-behavior.sh

dry-run-policy:
	$(MAKE) -C policy-dry-run dry-run

capture-golden-claims:
	bash scripts/kbs/capture-golden-via-probe.sh

capture-golden-from-pod:
	$(MAKE) -C policy-dry-run capture-from-pod

capture-golden-via-probe:
	bash scripts/kbs/capture-golden-via-probe.sh

enable-peer-pods-guest-rest-api:
	bash scripts/kbs/enable-peer-pods-guest-rest-api.sh

enable-guest-attestation-rest-api: enable-peer-pods-guest-rest-api

disable-guest-attestation-rest-api:
	bash scripts/kbs/disable-guest-attestation-rest-api.sh

fix-image-sign:
	bash scripts/kbs/fix-image-sign.sh

# --- Aliases (local profile) ---
register-dek: local-register-dek

register-policy: local-register-policy

fix-peer-pods:
	bash scripts/fix-peer-pods-azure.sh

deploy: local-deploy

deploy-demo: local-deploy

cluster: local-cluster

e2e: prepare setup-cosign local-register-dek local-register-policy relax-resource-policy-snp build local-deploy demo

demo:
	bash scripts/demo-present.sh

demo-act-ii:
	bash scripts/demo-act-ii-production.sh

demo-act-iii:
	bash scripts/demo-act-iii-mismatch.sh

demo-act-iii-cleanup:
	bash scripts/demo-act-iii-cleanup.sh

inspect-image:
	bash scripts/inspect-image.sh

smoke:
	bash scripts/smoke-test.sh
