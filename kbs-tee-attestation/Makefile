# KBS-only configuration for TEE (AMD SNP) remote attestation.
# Run on the Trustee/KBS cluster: oc login <kbs-cluster>
#
#   cp operator.env.example operator.env
#   # place inputs/dek.bin and inputs/cosign.pub
#   set -a && source operator.env && set +a
#   make configure

.PHONY: help configure ensure-remote-attestation register-policy register-dek \
        apply-resource-policy export-endpoint verify

help:
	@echo "KBS operator (Trustee cluster):"
	@echo "  make configure                 full flow (recommended)"
	@echo "  make ensure-remote-attestation Trustee + route + attestation checks"
	@echo "  make register-policy           cosign image policy + pub key"
	@echo "  make register-dek              DEK secret → KBS resource"
	@echo "  make apply-resource-policy     Rego: AzSnpVtpm only"
	@echo "  make export-endpoint           write output/ for inference cluster"
	@echo "  make verify                    post-config checks"

configure:
	bash scripts/configure.sh

ensure-remote-attestation:
	bash scripts/ensure-remote-attestation.sh

register-policy:
	bash scripts/register-policy.sh

register-dek:
	bash scripts/register-dek.sh

apply-resource-policy:
	bash scripts/apply-resource-policy.sh

export-endpoint:
	bash scripts/export-endpoint.sh

verify:
	bash scripts/verify.sh
