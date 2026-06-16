"""Thin wrapper around oc for cluster reads (requires oc login)."""

from __future__ import annotations

import base64
import gzip
import json
import os
import subprocess
from typing import Any

from .pod_parse import pod_from_k8s

TRUSTEE_NS = os.environ.get("TRUSTEE_NS", "trustee-operator-system")
DEMO_NAMESPACE = os.environ.get("DEMO_NAMESPACE", "confidential-inferencing")
PEER_NS = os.environ.get("PEER_NS", "openshift-sandboxed-containers-operator")
KBS_CONFIG = os.environ.get("KBS_CONFIG", "trusteeconfig-kbs-config")


def _oc(*args: str, timeout: int = 60) -> str:
    cmd = ["oc", *args]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("oc not found — install OpenShift CLI and oc login") from exc
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(err or f"oc failed: {' '.join(cmd)}")
    return proc.stdout


def whoami() -> str:
    return _oc("whoami").strip()


def get_pods(namespace: str = DEMO_NAMESPACE) -> list[dict[str, Any]]:
    raw = _oc(
        "get",
        "pods",
        "-n",
        namespace,
        "-l",
        "demo-role",
        "-o",
        "json",
        timeout=30,
    )
    data = json.loads(raw)
    pods: list[dict[str, Any]] = []
    for item in data.get("items", []):
        pods.append(pod_from_k8s(item))
    pods.sort(key=lambda p: p.get("createdAt", ""))
    return pods


def get_resource_policy() -> str:
    try:
        return _oc(
            "get",
            "configmap",
            "trusteeconfig-resource-policy",
            "-n",
            TRUSTEE_NS,
            "-o",
            "jsonpath={.data.policy\\.rego}",
            timeout=20,
        )
    except RuntimeError:
        return ""


def get_image_policy() -> str:
    try:
        raw = _oc(
            "get",
            "secret",
            os.environ.get("POLICY_SECRET", "trustee-image-policy"),
            "-n",
            TRUSTEE_NS,
            "-o",
            "jsonpath={.data.policy}",
            timeout=20,
        ).strip()
    except RuntimeError:
        return ""
    if not raw:
        return ""
    try:
        return base64.b64decode(raw).decode("utf-8", errors="replace")
    except Exception:
        return raw


def get_kbs_secrets() -> list[str]:
    try:
        raw = _oc(
            "get",
            "kbsconfig",
            KBS_CONFIG,
            "-n",
            TRUSTEE_NS,
            "-o",
            "json",
            timeout=20,
        )
        spec = json.loads(raw).get("spec", {})
        return list(spec.get("kbsSecretResources") or [])
    except RuntimeError:
        return []


def get_initdata_toml() -> str:
    b64 = _oc(
        "get",
        "configmap",
        "peer-pods-cm",
        "-n",
        PEER_NS,
        "-o",
        "jsonpath={.data.INITDATA}",
        timeout=20,
    ).strip()
    if not b64:
        return ""
    try:
        gz = base64.b64decode(b64)
        return gzip.decompress(gz).decode("utf-8", errors="replace")
    except Exception:
        return "(failed to decode INITDATA from peer-pods-cm)"


def get_confidential_route_host() -> str:
    try:
        return _oc(
            "get",
            "route",
            "inference-confidential",
            "-n",
            DEMO_NAMESPACE,
            "-o",
            "jsonpath={.spec.host}",
            timeout=15,
        ).strip()
    except RuntimeError:
        return ""


def fetch_trustee_tail(lines: int = 500) -> list[str]:
    """One-shot trustee log tail (for golden CVM policy backfill)."""
    try:
        raw = _oc(
            "logs",
            "-n",
            TRUSTEE_NS,
            "deployment/trustee-deployment",
            f"--tail={lines}",
            timeout=45,
        )
    except RuntimeError:
        return []
    return [ln.rstrip("\n") for ln in raw.splitlines() if ln.strip()]


def stream_trustee_logs():
    """Yield trustee log lines: recent tail first, then follow."""
    proc = subprocess.Popen(
        [
            "oc",
            "logs",
            "-n",
            TRUSTEE_NS,
            "deployment/trustee-deployment",
            "--tail=2000",
            "-f",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            yield line.rstrip("\n")
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def watch_pods(namespace: str = DEMO_NAMESPACE):
    """Yield JSON pod watch events (newline-delimited)."""
    proc = subprocess.Popen(
        [
            "oc",
            "get",
            "pods",
            "-n",
            namespace,
            "-l",
            "demo-role",
            "-w",
            "-o",
            "json",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and payload.get("kind") == "List":
                for item in payload.get("items") or []:
                    if isinstance(item, dict) and item.get("kind") == "Pod":
                        yield {"type": "ADDED", "object": item}
                continue
            yield payload
    finally:
        proc.terminate()
        proc.wait(timeout=5)
