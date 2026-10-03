"""Writes the context model's weight file from a trained checkpoint.

    python export.py --model checkpoint/ --out ../../Sources/ScrubCore/Resources [--name ContextModelBase]

The file holds the tokenizer (pieces, scores, the normalisation table), the
gate's word lists and the network: piece embeddings as int8 rows with one
float scale each, the body as fp16, biases, layer norms and the classifier as
float32. It is cut into even parts of at most 45 MB so each stays an ordinary
git file; ContextModel.swift joins them and checks the SHA-256 printed here, which
it holds in code. Export is deterministic: the same checkpoint and word lists
give the same bytes.
"""
import argparse
import base64
import collections
import hashlib
import json
import os
import re
import struct

import numpy as np
from safetensors.numpy import load_file

PART_LIMIT = 45_000_000
LABELS = ["O"] + [f"{p}-{c}" for c in ["PERSON", "USERNAME", "LOCATION", "ORG", "ID", "SECRET", "DOB"] for p in "BI"]


def common_words(prose_path, count=3000):
    """How common-words.txt was made from the training prose (extract_prose.py)."""
    # The commonest words of plain English prose with no people in it, and the
    # words that open a sentence whatever its subject.
    words = collections.Counter(w.lower() for w in re.findall(r"[A-Za-z]+", open(prose_path).read()))
    common = {w for w, _ in words.most_common(count)}
    common.update("i i'm i'll i've i'd mr mrs ms dr jan feb mar apr may jun jul aug sep sept oct nov dec monday tuesday wednesday "
                  "thursday friday saturday sunday january february march april june july august september october november "
                  "december".split())
    return sorted(common)


def dictionary_words(path):
    """Lowercase entries of a word list: ordinary words, not names."""
    return sorted({w for w in (line.strip() for line in open(path)) if w and w[0].islower()})


class Writer:
    def __init__(self):
        self.parts = []

    def u32(self, *values):
        self.parts.append(struct.pack(f"<{len(values)}I", *values))

    def i32(self, *values):
        self.parts.append(struct.pack(f"<{len(values)}i", *values))

    def f32(self, array):
        self.parts.append(np.ascontiguousarray(array, dtype="<f4").tobytes())

    def f16(self, array):
        self.parts.append(np.ascontiguousarray(array, dtype="<f2").tobytes())

    def f64(self, array):
        self.parts.append(np.ascontiguousarray(array, dtype="<f8").tobytes())

    def raw(self, data):
        self.parts.append(data)

    def strings(self, items):
        self.u32(len(items))
        for item in items:
            data = item if isinstance(item, bytes) else item.encode("utf-8")
            self.parts.append(struct.pack("<H", len(data)) + data)

    def bytes(self):
        return b"".join(self.parts)


def quantized(weights):
    """Embedding rows as int8 with one scale per row."""
    scale = np.maximum(np.abs(weights).max(axis=1), 1e-8) / 127
    rows = np.clip(np.round(weights / scale[:, None]), -127, 127).astype(np.int8)
    return rows, scale.astype(np.float32)


def stored(model_dir):
    """The tensors exactly as the file stores them, keyed as in the checkpoint.
    Works for a BERT body (the small model) and a RoBERTa one (the base model):
    RoBERTa counts positions from after its padding id, so its table starts there."""
    w = load_file(os.path.join(model_dir, "model.safetensors"))
    config = json.load(open(os.path.join(model_dir, "config.json")))
    prefix = "roberta." if "roberta.embeddings.word_embeddings.weight" in w else "bert."
    first = config["pad_token_id"] + 1 if prefix == "roberta." else 0
    rows, scale = quantized(w[prefix + "embeddings.word_embeddings.weight"])
    out = {"word_rows": rows, "word_scale": scale,
           "position": (w[prefix + "embeddings.position_embeddings.weight"][first:] + w[prefix + "embeddings.token_type_embeddings.weight"][0]).astype(np.float32),
           "embed_norm": (w[prefix + "embeddings.LayerNorm.weight"], w[prefix + "embeddings.LayerNorm.bias"]), "layers": [], "prefix": prefix}
    for i in range(config["num_hidden_layers"]):
        g = lambda k: w[f"{prefix}encoder.layer.{i}.{k}"]
        out["layers"].append({
            "qkv": np.concatenate([g("attention.self.query.weight"), g("attention.self.key.weight"), g("attention.self.value.weight")]).T.astype(np.float16),
            "qkv_bias": np.concatenate([g("attention.self.query.bias"), g("attention.self.key.bias"), g("attention.self.value.bias")]),
            "out": g("attention.output.dense.weight").T.astype(np.float16), "out_bias": g("attention.output.dense.bias"),
            "norm1": (g("attention.output.LayerNorm.weight"), g("attention.output.LayerNorm.bias")),
            "up": g("intermediate.dense.weight").T.astype(np.float16), "up_bias": g("intermediate.dense.bias"),
            "down": g("output.dense.weight").T.astype(np.float16), "down_bias": g("output.dense.bias"),
            "norm2": (g("output.LayerNorm.weight"), g("output.LayerNorm.bias"))})
    out["classifier"] = w["classifier.weight"].T.astype(np.float32)
    out["classifier_bias"] = w["classifier.bias"]
    return out, config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="trained checkpoint: config.json, model.safetensors, tokenizer.json")
    parser.add_argument("--common", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "common-words.txt"))
    parser.add_argument("--words", default="/usr/share/dict/words")
    parser.add_argument("--out", required=True)
    parser.add_argument("--name", default="ContextModel", help="the parts' file name: ContextModel (small) or ContextModelBase (base)")
    args = parser.parse_args()

    tokenizer = json.load(open(os.path.join(args.model, "tokenizer.json")))
    assert tokenizer["model"]["type"] == "Unigram" and tokenizer["normalizer"]["type"] == "Precompiled"
    pieces = tokenizer["model"]["vocab"]
    charsmap = base64.b64decode(tokenizer["normalizer"]["precompiled_charsmap"])
    tensors, config = stored(args.model)
    assert config["num_labels"] if "num_labels" in config else len(config["id2label"]) == len(LABELS)
    hidden = config["hidden_size"]

    out = Writer()
    out.raw(b"SCM1")
    out.u32(config["num_hidden_layers"], hidden, config["num_attention_heads"], config["intermediate_size"],
            len(tensors["position"]), len(pieces), len(LABELS))
    out.f32(np.array([config["layer_norm_eps"]]))
    out.i32(tokenizer["model"]["unk_id"], config["pad_token_id"], 0, 2)
    out.strings([p for p, _ in pieces])
    out.f64(np.array([s for _, s in pieces]))
    # The normaliser's own double-array trie, read as the tokenizer reads it.
    out.u32(len(charsmap))
    out.raw(charsmap)
    out.strings(LABELS)
    out.strings(sorted({w for w in (line.strip() for line in open(args.common)) if w}))
    out.strings(dictionary_words(args.words))
    out.f32(tensors["word_scale"])
    out.raw(tensors["word_rows"].tobytes())
    out.f32(tensors["position"])
    out.f32(tensors["embed_norm"][0]); out.f32(tensors["embed_norm"][1])
    for layer in tensors["layers"]:
        out.f16(layer["qkv"]); out.f32(layer["qkv_bias"])
        out.f16(layer["out"]); out.f32(layer["out_bias"])
        out.f32(layer["norm1"][0]); out.f32(layer["norm1"][1])
        out.f16(layer["up"]); out.f32(layer["up_bias"])
        out.f16(layer["down"]); out.f32(layer["down_bias"])
        out.f32(layer["norm2"][0]); out.f32(layer["norm2"][1])
    out.f32(tensors["classifier"]); out.f32(tensors["classifier_bias"])
    data = out.bytes()

    for name in os.listdir(args.out):
        if re.fullmatch(re.escape(args.name) + r"\.\d+\.bin", name):
            os.remove(os.path.join(args.out, name))
    count = (len(data) + PART_LIMIT - 1) // PART_LIMIT
    size = (len(data) + count - 1) // count
    for index in range(count):
        with open(os.path.join(args.out, f"{args.name}.{index + 1}.bin"), "wb") as f:
            f.write(data[index * size:(index + 1) * size])
    print(json.dumps({"bytes": len(data), "parts": count, "sha256": hashlib.sha256(data).hexdigest(),
                      "pieces": len(pieces)}))


if __name__ == "__main__":
    main()
