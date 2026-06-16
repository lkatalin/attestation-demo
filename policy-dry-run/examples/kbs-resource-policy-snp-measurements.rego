# KBS resource policy — AMD SNP + pinned launch measurement (stronger than TEE-type-only).
#
# 1. Capture real guest claims once (see capture-claims.sh):
#      ./capture-claims.sh --from-jwt /path/to/attestation.jwt --label prod-cvm
# 2. Replace MEASUREMENT_HEX and PCR11_HEX below with captured values.
# 3. Dry-run against captured fixture before apply:
#      ./dry-run.sh --rego examples/kbs-resource-policy-snp-measurements.rego \
#        --fixture captured/input-prod-cvm.json
#
package policy
import rego.v1

default allow = false

# Replace with values from captured/input-*.json (capture-claims.sh prints these).
snp_measurement if {
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["measurement"] == "MEASUREMENT_HEX"
}

snp_pcr11 if {
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["tpm"]["pcr11"] == "PCR11_HEX"
}

allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]
	snp_measurement
	snp_pcr11
}
