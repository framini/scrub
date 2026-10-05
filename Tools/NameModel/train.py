"""Trains the name model and writes its weights.

    python train.py --train train.jsonl --valid valid.jsonl --out NameModel.bin
    python train.py ... --gaps gaps.jsonl   # also scores a NameGaps dump

The weights file is little-endian: magic "SNM1", six UInt32 sizes (buckets,
embed, hidden, kernel, layers, shapes) and the layers' dilations; then one
float32 scale per embedding row and the rows as int8; then as float32 the
projection [in][out] and its bias, each convolution [tap][in][out] and its
bias, and the output weights and bias. NameModel.swift reads it in that order.
"""
import argparse
import json
import random
import re
import struct
from functools import lru_cache

import torch

from model import BUCKETS, EMBED, HIDDEN, KERNEL, DILATIONS, SHAPES, NameModel, buckets, shape, tokenize


@lru_cache(maxsize=None)
def features(word):
    return buckets(word), shape(word)


def encode(text, spans=()):
    tokens = tokenize(text)
    labels = [float(any(a < e and s < b for a, b in spans)) for s, e in tokens]
    return [features(text[s:e]) for s, e in tokens], labels, tokens


def batch_tensors(rows, device, dropout=0.0):
    """With dropout, a token sometimes loses its whole-word piece, so the
    model learns names from their spelling and context, not by heart."""
    ids, offsets, shapes, labels, lengths = [], [], [], [], []
    for feats, labs in rows:
        lengths.append(len(feats))
        labels.extend(labs)
        for bag, sh in feats:
            offsets.append(len(ids))
            ids.extend(bag[2:] if dropout and len(bag) > 2 and random.random() < dropout else bag)
            shapes.append(sh)
    t = lambda v, dtype: torch.tensor(v, dtype=dtype, device=device)
    return t(ids, torch.long), t(offsets, torch.long), t(shapes, torch.float32), t(lengths, torch.long), t(labels, torch.float32)


def load(path):
    rows = []
    for line in open(path):
        doc = json.loads(line)
        feats, labels, _ = encode(doc["text"], doc["spans"])
        if feats:
            rows.append((feats, labels))
    return rows


def predict(model, texts, device, threshold=0.5):
    model.eval()
    results = []
    with torch.no_grad():
        for text in texts:
            feats, labels, tokens = encode(text)
            if not feats:
                results.append([])
                continue
            ids, offsets, shapes, lengths, _ = batch_tensors([(feats, labels)], device)
            logits, mask = model(ids, offsets, shapes, lengths)
            probs = torch.sigmoid(logits[mask]).tolist()
            results.append([(tokens[i], p) for i, p in enumerate(probs) if p >= threshold])
    return results


def evaluate(model, rows, device):
    model.eval()
    tp = fp = fn = 0
    with torch.no_grad():
        for start in range(0, len(rows), 256):
            chunk = rows[start:start + 256]
            ids, offsets, shapes, lengths, labels = batch_tensors(chunk, device)
            logits, mask = model(ids, offsets, shapes, lengths)
            guess = logits[mask] > 0
            truth = labels > 0.5
            tp += int((guess & truth).sum()); fp += int((guess & ~truth).sum()); fn += int((~guess & truth).sum())
    precision, recall = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
    return precision, recall


def occurrences(word, text):
    pattern = re.compile(r"(?<![\w.-])" + re.escape(word) + r"(?![\w])")
    return [(m.start(), m.end()) for m in pattern.finditer(text)]


def score_gaps(model, path, device):
    """Per NameGaps category: share of cases the model alone gets right."""
    cases = [json.loads(line) for line in open(path)]
    tagged = predict(model, [c["prose"] for c in cases], device)
    scores, misses_left = {}, {}
    for case, hits in zip(cases, tagged):
        spans = [span for span, _ in hits]
        keep = case["category"] in ("wordsNotNames", "toolsAndOrgs")
        targets = [o for w in (case["keep"] if keep else case["names"]) for o in occurrences(w, case["prose"])]
        covered = lambda t: any(s < t[1] and t[0] < e for s, e in spans)
        ok = not any(covered(t) for t in targets) if keep else all(covered(t) for t in targets)
        if not ok and misses_left.get(case["category"], 3) > 0:
            misses_left[case["category"]] = misses_left.get(case["category"], 3) - 1
            words = (f"[{case['prose'][s:e]}]" if (s, e) in spans else case["prose"][s:e] for s, e in tokenize(case["prose"]))
            print(f"  miss {case['category']}: " + " ".join(words).replace("\n", "⏎"))
        total, good = scores.get(case["category"], (0, 0))
        scores[case["category"]] = (total + 1, good + ok)
    order = list(dict.fromkeys(c["category"] for c in cases))
    # One number to compare training runs by: the mean share right across categories.
    print(f"SCORE {sum(good / total for total, good in scores.values()) / len(scores):.4f}")
    print("| category | apple | detector | model | ")
    for name in order:
        total, good = scores[name]
        apple = sum(c["apple"] for c in cases if c["category"] == name)
        detector = sum(c["detector"] for c in cases if c["category"] == name)
        print(f"| {name} | {apple / total:4.0%} | {detector / total:4.0%} | {good / total:4.0%} |")


def quantize(table):
    """The embedding as shipped: int8 rows and one float32 scale per row."""
    scales = table.abs().amax(dim=1).clamp(min=1e-8) / 127
    return torch.round(table / scales[:, None]).clamp(-127, 127).to(torch.int8), scales


def export(model, path):
    state = {k: v.detach().cpu().float() for k, v in model.state_dict().items()}
    with open(path, "wb") as f:
        f.write(b"SNM1")
        f.write(struct.pack("<6I", BUCKETS, EMBED, HIDDEN, KERNEL, len(DILATIONS), SHAPES))
        f.write(struct.pack(f"<{len(DILATIONS)}I", *DILATIONS))
        rows, scales = quantize(state["embed.weight"])
        f.write(scales.numpy().astype("<f4").tobytes())
        f.write(rows.numpy().tobytes())
        f.write(state["project.weight"].t().contiguous().numpy().astype("<f4").tobytes())
        f.write(state["project.bias"].numpy().astype("<f4").tobytes())
        for i in range(len(DILATIONS)):
            f.write(state[f"convs.{i}.weight"].permute(2, 1, 0).contiguous().numpy().astype("<f4").tobytes())
            f.write(state[f"convs.{i}.bias"].numpy().astype("<f4").tobytes())
        f.write(state["out.weight"].numpy().astype("<f4").tobytes())
        f.write(state["out.bias"].numpy().astype("<f4").tobytes())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", required=True)
    parser.add_argument("--valid", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--gaps")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--load", help="skip training and score a saved checkpoint")
    args = parser.parse_args()
    torch.manual_seed(args.seed)
    random.seed(args.seed)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    train, valid = ([] if args.load else load(args.train)), load(args.valid)
    print(f"train docs={len(train)} valid docs={len(valid)} device={device}")
    model = NameModel().to(device)
    if args.load:
        model.load_state_dict(torch.load(args.load, map_location=device))
    print(f"parameters={sum(p.numel() for p in model.parameters()):,}")
    if args.load:
        args.epochs = 0
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-3, weight_decay=1e-5)
    steps = max(args.epochs * (len(train) // 128 + 1), 1)
    schedule = torch.optim.lr_scheduler.OneCycleLR(optimizer, max_lr=3e-3, total_steps=steps)
    loss_fn = torch.nn.BCEWithLogitsLoss()
    for epoch in range(args.epochs):
        model.train()
        random.shuffle(train)
        total = 0.0
        for start in range(0, len(train), 128):
            ids, offsets, shapes, lengths, labels = batch_tensors(train[start:start + 128], device, dropout=0.35)
            logits, mask = model(ids, offsets, shapes, lengths)
            loss = loss_fn(logits[mask], labels)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            schedule.step()
            total += loss.item()
        precision, recall = evaluate(model, valid, device)
        print(f"epoch {epoch + 1} loss={total / (len(train) / 128):.4f} valid precision={precision:.3f} recall={recall:.3f}")
    model.cpu()
    if not args.load:
        torch.save(model.state_dict(), args.out + ".pt")
    export(model, args.out)
    if args.gaps:
        score_gaps(model, args.gaps, "cpu")


if __name__ == "__main__":
    main()
