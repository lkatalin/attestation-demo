# KBS resource policy — AMD SNP confidential inferencing demo (ARO peer pods).
#
# Measurements (scripts/kbs/measure-attestation-behavior.sh):
#   - kata-remote / CVM: annotated-evidence contains "az-snp-vtpm" (serde key; logs say tee=AzSnpVtpm)
#   - baseline on worker: kbs-client falls back to "sample" only → deny
#
# Requires inference image built with kbs-client az-snp-vtpm-attester (scripts/build-kbs-client.sh).
package policy
import rego.v1

default allow = false

# Allow resource reads only for attested AMD SNP guests (peer-pod CVMs).
# Token key is serde rename "az-snp-vtpm" (Trustee logs still show tee=AzSnpVtpm).
allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]
}
