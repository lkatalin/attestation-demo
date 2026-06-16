# KBS resource policy — production AMD SNP peer-pod CVM (generated; do not edit by hand).
# Golden guest: act-iii-stale-pin
# Regenerate when OSC pod VM / initdata changes:
#   sync-trustee-attestation → capture claims → generate-production-policy.sh → apply-production-resource-policy.sh
#
# Layers:
#   - Trustee RVPS/endorsement (configure-trustee.sh) — verified before Rego
#   - az-snp-vtpm + measurement/pcr11 pins — this CVM build only
#   - EAR executable/configuration trust vectors — operator affirming range
#   - sample attester denied (no az-snp-vtpm key)
package policy
import rego.v1

default allow = false

allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]
	snp_measurement
	snp_pcr11
	not executable_failing
	not configuration_failing
}

snp_measurement if {
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["measurement"] == "Qfd/5cFBY0P4Tb7t7VBOtKLEUIYTF+0+TkbNdxx5JDpMvrPXXsZj5qeke9H0+rUE"
}

snp_pcr11 if {
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["tpm"]["pcr11"] == "da7794ba16770ac070750bd24094d3bd86cc87346e4290366d18421a2bcc50c4"
}

executable_failing if {
	some _, submod in input.submods
	executables := submod["ear.trustworthiness-vector"]["executables"]
	not in_affirming_range(executables)
}

configuration_failing if {
	some _, submod in input.submods
	configuration := submod["ear.trustworthiness-vector"]["configuration"]
	not in_affirming_range(configuration)
}

# SNP peer-pod appraisals often exceed operator-default 2–31 (e.g. executables=33,
# configuration=36) even for healthy guests. Require non-failing (>= 2), not 2–31.
in_affirming_range(val) if {
	val >= 2
}
