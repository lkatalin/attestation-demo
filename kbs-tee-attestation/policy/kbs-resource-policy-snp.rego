# KBS resource policy — AMD SNP TEE only (deny sample attester on non-CVM workloads).
package policy
import rego.v1

default allow = false

allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]
}
