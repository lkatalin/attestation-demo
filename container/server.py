#!/usr/bin/env python3
"""Minimal inference API for the demo transformer."""

from __future__ import annotations

import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

import torch
import torch.nn as nn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from model_arch import TinyTransformerLM, load_checkpoint

MODEL_PATH = Path(os.environ.get("MODEL_PATH", "/tmp/inference-data/model.pt"))
DEMO_MODE = os.environ.get("DEMO_MODE", "confidential")
DEMO_RUNTIME = os.environ.get("DEMO_RUNTIME", "unknown")
READY = False
ENC_MODEL = Path("/app/encrypted/model.pt.enc")
PLAINTEXT_BAKED = Path("/app/plaintext/model.pt")
MODEL: TinyTransformerLM | None = None
VOCAB: dict[str, int] = {}
INV: dict[int, str] = {}
DEVICE = torch.device("cpu")


class GenerateRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=256)
    max_new_tokens: int = Field(48, ge=1, le=128)


class GenerateResponse(BaseModel):
    prompt: str
    completion: str
    full_text: str


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global READY, MODEL, VOCAB, INV
    if not MODEL_PATH.exists():
        raise RuntimeError(f"decrypted model not found at {MODEL_PATH}")
    MODEL, VOCAB, INV = load_checkpoint(MODEL_PATH, DEVICE)
    MODEL.eval()
    READY = True
    yield
    READY = False


app = FastAPI(title="confidential-inferencing-demo", lifespan=lifespan)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    if not READY:
        raise HTTPException(status_code=503, detail="model not loaded")
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    return healthz()


@app.post("/v1/generate", response_model=GenerateResponse)
def generate(req: GenerateRequest) -> GenerateResponse:
    if MODEL is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    prompt = req.prompt.lower()
    ids = [VOCAB.get(c, VOCAB.get("<pad>", 0)) for c in prompt]
    if not ids:
        raise HTTPException(status_code=400, detail="prompt has no known characters")
    generated = ids.copy()
    with torch.no_grad():
        for _ in range(req.max_new_tokens):
            x = torch.tensor([generated[-MODEL.max_len :]], dtype=torch.long, device=DEVICE)
            logits = MODEL(x)[0, -1]
            next_id = int(torch.argmax(logits).item())
            generated.append(next_id)
            ch = INV.get(next_id, "")
            if ch in ("", "<pad>"):
                break
    text = "".join(INV[i] for i in generated)
    completion = text[len(prompt) :]
    return GenerateResponse(prompt=prompt, completion=completion, full_text=text)


@app.get("/demo/info")
def demo_info() -> dict[str, object]:
    """Expose how this pod loaded the model (for live demos)."""
    manifest_path = Path(os.environ.get("MANIFEST_PATH", "/app/data/manifest.json"))
    meta: dict[str, object] = {}
    if manifest_path.exists() and manifest_path.is_file():
        meta = json.loads(manifest_path.read_text())
    return {
        "demo_mode": DEMO_MODE,
        "demo_runtime": DEMO_RUNTIME,
        "model_path": str(MODEL_PATH),
        "model_loaded": READY,
        "shipping_artifact": {
            "encrypted_weights_in_image": str(ENC_MODEL),
            "encrypted_present": ENC_MODEL.is_file(),
            "encrypted_size_bytes": ENC_MODEL.stat().st_size if ENC_MODEL.is_file() else 0,
        },
        "plaintext_control_baked_in_image": PLAINTEXT_BAKED.is_file(),
        "decrypt_manifest": meta,
        "narration": (
            "confidential: loaded via KBS DEK + decrypt of model.pt.enc inside CVM. "
            "plaintext: demo control arm — skipped KBS and used /app/plaintext/model.pt. "
            "Same image; compare /demo/info across routes."
        ),
    }


@app.get("/")
def root() -> dict[str, object]:
    info = demo_info()
    return {"service": "confidential-inferencing-demo", **info}
