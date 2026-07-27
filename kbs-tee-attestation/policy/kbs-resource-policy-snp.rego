# KBS resource policy — AMD SNP TEE only (deny sample attester on non-CVM workloads).
package policy
import rego.v1

default allow = false

# Trustee v1.0.0 uses "azsnpvtpm", v1.1.0+ supports both "az-snp-vtpm" and "azsnpvtpm".
allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]
}

allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["azsnpvtpm"]
}
