#!/usr/bin/env python3
"""Patch kata remote configuration.toml for guest attestation REST (OSC peer pods)."""
import os
import re
import sys
from pathlib import Path


def main() -> None:
    kp = os.environ["KP"]
    cfg = Path(os.environ["CFG"])
    text = cfg.read_text()

    if not re.search(r'enable_annotations\s*=\s*\[[^\]]*"kernel_params"', text):
        text, n = re.subn(
            r"(enable_annotations\s*=\s*\[)",
            r'\1"kernel_params", ',
            text,
            count=1,
        )
        if n != 1:
            sys.exit("could not add kernel_params to enable_annotations")

    if re.search(r'^kernel_params\s*=\s*"', text, flags=re.M):
        text = re.sub(
            r"^kernel_params\s*=.*",
            f'kernel_params = "{kp}"',
            text,
            count=1,
            flags=re.M,
        )
    elif re.search(r"^#\s*kernel_params\s*=", text, flags=re.M):
        text = re.sub(
            r"^#\s*kernel_params\s*=.*",
            f'kernel_params = "{kp}"',
            text,
            count=1,
            flags=re.M,
        )
    else:
        sys.exit("could not locate kernel_params line to patch")

    bak = cfg.with_suffix(cfg.suffix + ".bak-guest-rest-api")
    if not bak.exists():
        bak.write_text(cfg.read_text())

    cfg.write_text(text)
    print("patched enable_annotations + kernel_params")


if __name__ == "__main__":
    main()
