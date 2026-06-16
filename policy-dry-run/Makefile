.PHONY: help dry-run dry-run-strict dry-run-static capture capture-from-pod check-handoff \
	customer-handoff-export-bundle customer-handoff-import-bundle \
	customer-handoff-export-claims customer-handoff-import-claims \
	production production-strict production-cluster \
	check-workload-kbs-path check-rvps-initdata check-remote-contract \
	check-image-contract diff-cluster-policy check-kbs-tenancy \
	dry-run-measurements dry-run-rotation check-platform-policy check-attestation-slo

help:
	@echo "Offline attestation policy workflow:"
	@echo "  make dry-run                 Rego + cosign + DEK fetch stack"
	@echo "  make dry-run-strict          warnings fail the run"
	@echo "  make dry-run-static          static checks only (no OPA)"
	@echo "  make check-handoff           KBS output/ bundle (URLs, certs, CDH initdata)"
	@echo ""
	@echo "Cross-cluster handoff:"
	@echo "  make customer-handoff-export-bundle   model owner → customer KBS pack"
	@echo "  make customer-handoff-import-bundle PACK=…  customer validates KBS pack"
	@echo "  make customer-handoff-export-claims FROM=… LABEL=…  customer → model owner pins"
	@echo "  make customer-handoff-import-claims PACK=…  model owner validates pins pack"
	@echo ""
	@echo "Production dry-run suite (offline):"
	@echo "  make production              run-production-checks.sh (all offline gates)"
	@echo "  make production-strict       same, --strict"
	@echo "  make production-cluster      include oc-dependent drift + log scrape"
	@echo ""
	@echo "Individual production checks:"
	@echo "  make check-workload-kbs-path   CDH REST path, USER, hostPath, probes"
	@echo "  make check-rvps-initdata       initdata / RVPS endorsement alignment"
	@echo "  make check-remote-contract     handoff + TLS + deployment alignment"
	@echo "  make check-image-contract      cosign, digest pin, no secrets in image"
	@echo "  make diff-cluster-policy       git vs live Rego + image policy (oc login)"
	@echo "  make check-kbs-tenancy         blast-radius / deny-by-default linter"
	@echo "  make dry-run-measurements      measurement-pinned Rego + OPA"
	@echo "  make dry-run-rotation          rotation tabletop / cert horizon"
	@echo "  make check-platform-policy     SCC, kata-remote, SA, hostPath"
	@echo "  make check-attestation-slo     expected Trustee patterns (+ --scrape-logs)"
	@echo ""
	@echo "After one successful guest attest:"
	@echo "  make capture FROM=claims.json LABEL=prod-cvm"
	@echo "  make capture-from-pod          # live: Ready inference-confidential pod"

dry-run:
	bash dry-run.sh

dry-run-strict:
	bash dry-run.sh --strict

dry-run-static:
	bash dry-run.sh --skip-opa

check-handoff:
	bash check-handoff.sh ../kbs-tee-attestation/output

customer-handoff-export-bundle:
	bash customer-handoff.sh export-bundle --bundle ../kbs-tee-attestation/output

customer-handoff-import-bundle:
	@test -n "$(PACK)" || (echo "Usage: make customer-handoff-import-bundle PACK=path/to/bundle.tar.gz" >&2; exit 2)
	bash customer-handoff.sh import-bundle "$(PACK)"

customer-handoff-export-claims:
	@test -n "$(FROM)" && test -n "$(LABEL)" || (echo "Usage: make customer-handoff-export-claims FROM=claims.json LABEL=acme [--cluster-info]" >&2; exit 2)
	bash customer-handoff.sh export-claims --from "$(FROM)" --label "$(LABEL)" $(if $(CLUSTER_INFO),--cluster-info,)

customer-handoff-import-claims:
	@test -n "$(PACK)" || (echo "Usage: make customer-handoff-import-claims PACK=path/to/customer-claims.tar.gz" >&2; exit 2)
	bash customer-handoff.sh import-claims "$(PACK)"

production:
	bash run-production-checks.sh

production-strict:
	STRICT=1 bash run-production-checks.sh --strict

production-cluster:
	bash run-production-checks.sh --with-cluster

check-workload-kbs-path:
	bash check-workload-kbs-path.sh

check-rvps-initdata:
	bash check-rvps-initdata.sh

check-remote-contract:
	bash check-remote-contract.sh

check-image-contract:
	bash check-image-contract.sh

diff-cluster-policy:
	bash diff-cluster-policy.sh

check-kbs-tenancy:
	bash check-kbs-tenancy.sh

dry-run-measurements:
	bash dry-run-measurements.sh

dry-run-rotation:
	bash dry-run-rotation.sh

check-platform-policy:
	bash check-platform-policy.sh

check-attestation-slo:
	bash check-attestation-slo.sh

capture:
	@test -n "$(FROM)" || (echo "Usage: make capture FROM=claims.json LABEL=name" >&2; exit 2)
	bash capture-claims.sh --from "$(FROM)" --label "$(LABEL)"

capture-from-pod:
	bash capture-golden-from-pod.sh \
	  $(if $(LABEL),--label "$(LABEL)",) \
	  $(if $(POD),--pod "$(POD)",) \
	  $(if $(NO_WAIT),--no-wait,) \
	  $(if $(ANY_READY),--any-ready,) \
	  $(if $(WAIT_TIMEOUT_SEC),--wait-timeout "$(WAIT_TIMEOUT_SEC)",)
