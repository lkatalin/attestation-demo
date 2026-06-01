#!/usr/bin/env bash
# Full KBS operator flow for TEE attestation (run on Trustee cluster after prerequisites).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/ensure-remote-attestation.sh"
bash "$SCRIPT_DIR/register-policy.sh"
bash "$SCRIPT_DIR/register-dek.sh"
bash "$SCRIPT_DIR/apply-resource-policy.sh"
bash "$SCRIPT_DIR/export-endpoint.sh"
bash "$SCRIPT_DIR/verify.sh"
