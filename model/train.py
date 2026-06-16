#!/usr/bin/env python3
"""Train a tiny character-level transformer on a few demo sentences."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn as nn

CORPUS = [
    "confidential inferencing runs inside a hardware trusted execution environment",
    "the key broker releases the data encryption key only after attestation succeeds",
    "encrypted model weights stay ciphertext until the guest decrypts them inside the cvm",
    "open shift peer pods schedule workloads into confidential virtual machines on aro",
    "this demo proves end to end coco trustee and kbs integration for small models",
]

PAD = "<pad>"


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
        if t > self.max_len:
            raise ValueError(f"sequence length {t} exceeds max_len {self.max_len}")
        pos = torch.arange(t, device=x.device).unsqueeze(0).expand(b, t)
        h = self.token_emb(x) + self.pos_emb(pos)
        mask = nn.Transformer.generate_square_subsequent_mask(t, device=x.device)
        h = self.encoder(h, mask=mask, is_causal=True)
        return self.head(h)


def build_vocab(texts: list[str]) -> dict[str, int]:
    chars = sorted(set("".join(texts)))
    vocab = {PAD: 0}
    for i, ch in enumerate(chars, start=1):
        vocab[ch] = i
    return vocab


def encode(text: str, vocab: dict[str, int]) -> list[int]:
    return [vocab[c] for c in text]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, default=Path("artifacts"))
    parser.add_argument("--epochs", type=int, default=400)
    parser.add_argument("--lr", type=float, default=3e-3)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    vocab = build_vocab(CORPUS)
    inv_vocab = {i: c for c, i in vocab.items()}
    sequences = [encode(s, vocab) for s in CORPUS]

    model = TinyTransformerLM(vocab_size=len(vocab))
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr)
    loss_fn = nn.CrossEntropyLoss(ignore_index=0)

    model.train()
    for epoch in range(args.epochs):
        total = 0.0
        for seq in sequences:
            if len(seq) < 2:
                continue
            x = torch.tensor([seq[:-1]], dtype=torch.long)
            y = torch.tensor([seq[1:]], dtype=torch.long)
            opt.zero_grad()
            logits = model(x)
            loss = loss_fn(logits.view(-1, logits.size(-1)), y.view(-1))
            loss.backward()
            opt.step()
            total += loss.item()
        if (epoch + 1) % 100 == 0:
            print(f"epoch {epoch + 1}/{args.epochs} loss={total / len(sequences):.4f}")

    payload = {
        "model_state_dict": model.state_dict(),
        "vocab": vocab,
        "inv_vocab": inv_vocab,
        "corpus": CORPUS,
        "arch": {
            "d_model": 64,
            "nhead": 4,
            "num_layers": 2,
            "max_len": 128,
        },
    }
    out = args.out_dir / "model.pt"
    torch.save(payload, out)
    meta = {
        "vocab_size": len(vocab),
        "corpus_sentences": len(CORPUS),
        "artifact": out.name,
    }
    (args.out_dir / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
