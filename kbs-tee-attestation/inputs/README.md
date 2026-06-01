# Operator inputs (from model owner)

Place these files here before running `make configure`:

| File | Description |
|------|-------------|
| `dek.bin` | Raw data-encryption key for the encrypted model (32 bytes typical) |
| `cosign.pub` | Public key used to verify the signed workload image |

The model owner generates these with the main repo (`make prepare`, `make setup-cosign`) and shares this directory (or a tarball).

Do **not** commit `dek.bin` or private keys to git.
