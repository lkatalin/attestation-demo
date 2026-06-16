"""Shared model definition for train (optional) and inference."""

from __future__ import annotations

from pathlib import Path

import torch
import torch.nn as nn


class TinyTransformerLM(nn.Module):
    def __init__(
        self,
        vocab_size: int,
        d_model: int = 64,
        nhead: int = 4,
        num_layers: int = 2,
        max_len: int = 128,
    ) -> None:
        super().__init__()
        self.max_len = max_len
        self.token_emb = nn.Embedding(vocab_size, d_model)
        self.pos_emb = nn.Embedding(max_len, d_model)
        layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=nhead,
            dim_feedforward=d_model * 4,
            batch_first=True,
        )
        self.encoder = nn.TransformerEncoder(layer, num_layers=num_layers)
        self.head = nn.Linear(d_model, vocab_size)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        b, t = x.shape
        pos = torch.arange(t, device=x.device).unsqueeze(0).expand(b, t)
        h = self.token_emb(x) + self.pos_emb(pos)
        mask = nn.Transformer.generate_square_subsequent_mask(t, device=x.device)
        h = self.encoder(h, mask=mask, is_causal=True)
        return self.head(h)


def load_checkpoint(path: Path, device: torch.device) -> tuple[TinyTransformerLM, dict[str, int], dict[int, str]]:
    payload = torch.load(path, map_location=device, weights_only=False)
    arch = payload["arch"]
    model = TinyTransformerLM(vocab_size=len(payload["vocab"]), **arch)
    model.load_state_dict(payload["model_state_dict"])
    model.to(device)
    return model, payload["vocab"], {int(k): v for k, v in payload["inv_vocab"].items()}
