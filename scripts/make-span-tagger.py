#!/usr/bin/env python3
"""Builds Models/SpanTagger.bin, the span tagger's weights, from its downloaded checkpoint.

usage: make-span-tagger.py CHECKPOINT_DIR [OUT]

CHECKPOINT_DIR holds model.safetensors and tokenizer.json (see THIRD_PARTY_NOTICES.md for
where they come from). Needs numpy only, and never touches the network. The output is
git-ignored; its SHA-256 must match SpanTagger.checksum or Scrub runs without it.

Layout, little-endian: "STG1"; uint32 piece count, then each piece as uint16 byte length
and UTF-8 bytes; float64 scores; uint32 ids of [SEP_TEXT], [P] and [E]; zeros to a multiple of 64 bytes; then every
tensor in TENSORS order as float16, row-major, in the checkpoint's own shape.
"""
import hashlib, json, os, struct, sys
import numpy as np

LAYERS = 12
ENCODER = ["attention.self.query_proj", "attention.self.key_proj", "attention.self.value_proj", "attention.output.dense"]
TENSORS = ["encoder.embeddings.word_embeddings.weight", "encoder.embeddings.LayerNorm.weight", "encoder.embeddings.LayerNorm.bias",
           "encoder.encoder.rel_embeddings.weight", "encoder.encoder.LayerNorm.weight", "encoder.encoder.LayerNorm.bias"]
for i in range(LAYERS):
    p = f"encoder.encoder.layer.{i}."
    for name in ENCODER:
        TENSORS += [p + name + ".weight", p + name + ".bias"]
    TENSORS += [p + "attention.output.LayerNorm.weight", p + "attention.output.LayerNorm.bias",
                p + "intermediate.dense.weight", p + "intermediate.dense.bias",
                p + "output.dense.weight", p + "output.dense.bias", p + "output.LayerNorm.weight", p + "output.LayerNorm.bias"]
for part in ["project_start", "project_end", "out_project"]:
    for layer in ["0", "3"]:
        TENSORS += [f"span_rep.span_rep_layer.{part}.{layer}.weight", f"span_rep.span_rep_layer.{part}.{layer}.bias"]
TENSORS += ["count_embed.pos_embedding.weight", "count_embed.gru.weight_ih_l0", "count_embed.gru.weight_hh_l0",
            "count_embed.gru.bias_ih_l0", "count_embed.gru.bias_hh_l0", "count_embed.projector.0.weight", "count_embed.projector.0.bias",
            "count_embed.projector.2.weight", "count_embed.projector.2.bias", "count_pred.0.weight", "count_pred.0.bias",
            "count_pred.2.weight", "count_pred.2.bias"]


def safetensors(path):
    with open(path, "rb") as f:
        size = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(size))
        base = 8 + size
    data = np.memmap(path, dtype=np.uint8, mode="r")
    out = {}
    for name, info in header.items():
        if name == "__metadata__":
            continue
        assert info["dtype"] == "F32", name
        start, end = info["data_offsets"]
        out[name] = np.frombuffer(data[base + start:base + end], dtype="<f4").reshape(info["shape"])
    return out


def main():
    source = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "Models", "SpanTagger.bin")
    tokenizer = json.load(open(os.path.join(source, "tokenizer.json"), encoding="utf-8"))
    model = tokenizer["model"]
    assert model["type"] == "Unigram" and model["unk_id"] == 3 and not model.get("byte_fallback")
    added = {t["content"]: t["id"] for t in tokenizer["added_tokens"]}
    weights = safetensors(os.path.join(source, "model.safetensors"))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "wb") as f:
        f.write(b"STG1")
        vocab = model["vocab"]
        f.write(struct.pack("<I", len(vocab)))
        for piece, _ in vocab:
            raw = piece.encode("utf-8")
            f.write(struct.pack("<H", len(raw)) + raw)
        f.write(np.array([score for _, score in vocab], dtype="<f8").tobytes())
        f.write(struct.pack("<3I", added["[SEP_TEXT]"], added["[P]"], added["[E]"]))
        f.write(b"\0" * (-f.tell() % 64))
        for name in TENSORS:
            f.write(weights[name].astype("<f2").tobytes())
    digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
    print(f"{out}\n{os.path.getsize(out)} bytes, sha256 {digest}")


if __name__ == "__main__":
    main()
