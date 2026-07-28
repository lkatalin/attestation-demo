# Intentionally wrong — uses PascalCase log label instead of JWT key az-snp-vtpm or azsnpvtpm.
package policy
import rego.v1

default allow = false

allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["AzSnpVtpm"]
}
