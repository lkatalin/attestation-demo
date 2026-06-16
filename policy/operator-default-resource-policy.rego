# Trustee operator default resource policy (reference copy for dry-run / diagnose).
# Live cluster: oc get cm trusteeconfig-resource-policy -o jsonpath='{.data.policy\.rego}'
#
# Problem for AMD SNP peer pods without full SNP TCB RVPS entries:
#   hardware_failing may deny even when Verifier logs tee=AzSnpVtpm and POST /attest 200.
package policy
import rego.v1

default allow = false
default hardware_failing = false

allow if {
	count(input.submods) > 0
	not executable_failing
	not configuration_failing
	not hardware_failing
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

hardware_failing if {
	some _, submod in input.submods
	hardware := submod["ear.trustworthiness-vector"]["hardware"]
	not in_affirming_range(hardware)
}

in_affirming_range(val) if {
	val >= 2
	val <= 31
}
