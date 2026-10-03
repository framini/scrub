"""Trains the address model and writes its weights.

    python train.py --train train.jsonl --valid valid.jsonl --test test.jsonl --out AddressModel.bin

The weights file is little-endian: magic "SAM1", seven UInt32 sizes
(buckets, embed, hidden, kernel, layers, shapes, labels) and the layers'
dilations; then one float32 scale per embedding row and the rows as int8;
then as float32 the projection [in][out] and its bias, each convolution
[tap][in][out] and its bias, and the output weights [in][labels] and biases.
AddressModel.swift reads it in that order.
"""
import argparse
import json
import math
import random
import struct
from functools import lru_cache

import torch

from model import BUCKETS, DILATIONS, EMBED, HIDDEN, KERNEL, LABELS, SHAPES, AddressModel, buckets, is_digit, is_letter, line_shapes, shape, tokenize

THRESHOLD = 0.5


@lru_cache(maxsize=200_000)
def features(word):
    return buckets(word), shape(word)


def encode(text, spans=()):
    tokens = tokenize(text)
    lines = line_shapes(text, tokens)
    labels = []
    for s, e in tokens:
        label = 0
        for a, b in spans:
            if a < e and s < b:
                label = 1 if s <= a else 2
                break
        labels.append(label)
    feats = []
    for (s, e), flags in zip(tokens, lines):
        bag, sh = features(text[s:e])
        feats.append((bag, sh + flags))
    return feats, labels, tokens


def batch_tensors(rows, device, dropout=0.0):
    ids, offsets, shapes, labels, lengths = [], [], [], [], []
    for feats, labs in rows:
        lengths.append(len(feats))
        labels.extend(labs)
        for bag, sh in feats:
            offsets.append(len(ids))
            ids.extend(bag[2:] if dropout and len(bag) > 2 and random.random() < dropout else bag)
            shapes.append(sh)
    t = lambda v, dtype: torch.tensor(v, dtype=dtype, device=device)
    return t(ids, torch.long), t(offsets, torch.long), t(shapes, torch.float32), t(lengths, torch.long), t(labels, torch.long)


def load(path, limit=None):
    """The documents only; features are made a batch at a time, to keep memory low."""
    docs = []
    for index, line in enumerate(open(path)):
        if limit and index >= limit:
            break
        doc = json.loads(line)
        if doc["text"].strip():
            docs.append((doc["text"], [tuple(s) for s in doc["spans"]]))
    return docs


def rows_of(docs):
    return [encode(text, spans)[:2] for text, spans in docs]


def decode(text, tokens, probs, threshold=THRESHOLD, numberless=False):
    """Address spans from per-token [O, B, I] probabilities, in code points.

    A token is inside an address when B + I reaches the threshold; a run of
    such tokens is one address, split where a token is more likely to begin
    one than to continue it. Punctuation and line breaks at either end are
    dropped, and an address must hold two words and a digit; with
    `numberless`, two pieces (parted by a comma, semicolon or line break) do instead of the digit."""
    spans, current = [], None
    for index, (o, b, i) in enumerate(probs):
        inside = b + i >= threshold
        if inside and current is not None and b > i and b > o:
            spans.append(current)
            current = None
        if inside:
            current = [index, index] if current is None else [current[0], index]
        elif current is not None:
            spans.append(current)
            current = None
    if current is not None:
        spans.append(current)
    result = []
    for first, last in spans:
        word = lambda k: any(is_letter(ch) or is_digit(ch) for ch in text[tokens[k][0]:tokens[k][1]])
        while first <= last and not word(first):
            first += 1
        while last >= first and not word(last):
            # "(Biella)" keeps its closing bracket.
            if text[tokens[last][0]:tokens[last][1]] == ")" and "(" in text[tokens[first][0]:tokens[last][0]]:
                break
            last -= 1
        if first > last:
            continue
        pieces = [text[tokens[k][0]:tokens[k][1]] for k in range(first, last + 1)]
        words = [p for p in pieces if any(is_letter(ch) for ch in p)]
        digit = any(any(is_digit(ch) for ch in p) for p in pieces)
        parted = numberless and any(p in (",", ";", "\n") for p in pieces)
        if len(words) < 2 or not (digit or parted):
            continue
        result.append((tokens[first][0], tokens[last][1]))
    return result


def predict(model, texts, device, batch=64):
    model.eval()
    out = []
    with torch.no_grad():
        for start in range(0, len(texts), batch):
            chunk = texts[start:start + batch]
            encoded = [encode(t) for t in chunk]
            rows = [(f, l) for f, l, _ in encoded]
            nonempty = [k for k, (f, _) in enumerate(rows) if f]
            probs_all = [[] for _ in chunk]
            if nonempty:
                ids, offsets, shapes, lengths, _ = batch_tensors([rows[k] for k in nonempty], device)
                logits, mask = model(ids, offsets, shapes, lengths)
                probs = torch.softmax(logits, dim=-1).cpu()
                for row, k in enumerate(nonempty):
                    probs_all[k] = probs[row, :int(lengths[row])].tolist()
            for text, (_, _, tokens), probs in zip(chunk, encoded, probs_all):
                out.append((tokens, probs))
    return out


def normal(text, span):
    a, b = span
    while b > a and text[b - 1] in ".":
        b -= 1
    while a < b and text[a] in "#":
        a += 1
    return (a, b)


def span_scores(model, docs, device, threshold=THRESHOLD, show=0):
    """Exact and overlap matches of predicted addresses against the labelled ones, and documents with a false alarm."""
    predicted = predict(model, [d["text"] for d in docs], device)
    gold_total = pred_total = exact = covered = false_docs = negatives = 0
    shown = 0
    for doc, (tokens, probs) in zip(docs, predicted):
        found = decode(doc["text"], tokens, probs, threshold, numberless=True)
        # A full stop or "#" at an address's edge is read with the text around it.
        gold = [normal(doc["text"], s) for s in doc["spans"]]
        found = [normal(doc["text"], s) for s in found]
        gold_total += len(gold)
        pred_total += len(found)
        exact += len(set(found) & set(gold))
        covered += sum(1 for a, b in gold if any(s <= a and b <= e for s, e in found))
        stray = [f for f in found if not any(f[0] < b and a < f[1] for a, b in gold)]
        if not gold:
            negatives += 1
            false_docs += bool(stray)
        if show and shown < show and (set(found) != set(gold)):
            shown += 1
            t = doc["text"]
            print("  gold:", [t[a:b] for a, b in gold], "\n  found:", [t[a:b] for a, b in found])
    precision = exact / max(pred_total, 1)
    recall = exact / max(gold_total, 1)
    return {"exact_recall": recall, "exact_precision": precision, "covered": covered / max(gold_total, 1),
            "false_alarm_docs": false_docs / max(negatives, 1), "gold": gold_total, "negatives": negatives}


def quantize(table):
    scales = table.abs().amax(dim=1).clamp(min=1e-8) / 127
    return torch.round(table / scales[:, None]).clamp(-127, 127).to(torch.int8), scales


def export(model, path):
    state = {k: v.detach().cpu().float() for k, v in model.state_dict().items()}
    with open(path, "wb") as f:
        f.write(b"SAM1")
        f.write(struct.pack("<7I", BUCKETS, EMBED, HIDDEN, KERNEL, len(DILATIONS), SHAPES, LABELS))
        f.write(struct.pack(f"<{len(DILATIONS)}I", *DILATIONS))
        rows, scales = quantize(state["embed.weight"])
        f.write(scales.numpy().astype("<f4").tobytes())
        f.write(rows.numpy().tobytes())
        f.write(state["project.weight"].t().contiguous().numpy().astype("<f4").tobytes())
        f.write(state["project.bias"].numpy().astype("<f4").tobytes())
        for i in range(len(DILATIONS)):
            f.write(state[f"convs.{i}.weight"].permute(2, 1, 0).contiguous().numpy().astype("<f4").tobytes())
            f.write(state[f"convs.{i}.bias"].numpy().astype("<f4").tobytes())
        f.write(state["out.weight"].t().contiguous().numpy().astype("<f4").tobytes())
        f.write(state["out.bias"].numpy().astype("<f4").tobytes())


def quantized(model):
    """The model as shipped: its embedding rounded to int8 rows."""
    with torch.no_grad():
        rows, scales = quantize(model.embed.weight)
        model.embed.weight.copy_(rows.float() * scales[:, None])
    return model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", required=True)
    parser.add_argument("--valid", required=True)
    parser.add_argument("--test")
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--load", help="skip training and score a saved checkpoint")
    parser.add_argument("--init", help="start from a saved checkpoint (a line flag it lacks starts at zero)")
    parser.add_argument("--lr", type=float, default=3e-3)
    args = parser.parse_args()
    torch.manual_seed(args.seed)
    random.seed(args.seed)
    torch.set_num_threads(4)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    train = [] if args.load else load(args.train, args.limit)
    valid_docs = [{"text": t, "spans": s} for t, s in load(args.valid)]
    print(f"train docs={len(train)} valid docs={len(valid_docs)} device={device}", flush=True)
    model = AddressModel().to(device)
    if args.load:
        model.load_state_dict(torch.load(args.load, map_location=device))
        args.epochs = 0
    if args.init:
        state = torch.load(args.init, map_location="cpu")
        weight = state["project.weight"]
        if weight.shape[1] < EMBED + SHAPES:
            state["project.weight"] = torch.cat([weight, weight.new_zeros(weight.shape[0], EMBED + SHAPES - weight.shape[1])], dim=1)
        model.load_state_dict(state)
        model.to(device)
    print(f"parameters={sum(p.numel() for p in model.parameters()):,}")
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-5)
    steps = max(args.epochs * (len(train) // 128 + 1), 1)
    schedule = torch.optim.lr_scheduler.OneCycleLR(optimizer, max_lr=args.lr, total_steps=steps)
    loss_fn = torch.nn.CrossEntropyLoss()
    for epoch in range(args.epochs):
        model.train()
        random.shuffle(train)
        total = 0.0
        for start in range(0, len(train), 128):
            ids, offsets, shapes, lengths, labels = batch_tensors(rows_of(train[start:start + 128]), device, dropout=0.25)
            logits, mask = model(ids, offsets, shapes, lengths)
            loss = loss_fn(logits[mask], labels)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            schedule.step()
            total += loss.item()
        scores = span_scores(model, valid_docs, device)
        print(f"epoch {epoch + 1} loss={total / (len(train) / 128):.4f} valid {json.dumps({k: round(v, 4) for k, v in scores.items()})}", flush=True)
    model.cpu()
    if not args.load:
        torch.save(model.state_dict(), args.out + ".pt")
    quantized(model)
    export(model, args.out)
    print("valid (int8):", json.dumps({k: round(v, 4) for k, v in span_scores(model, valid_docs, "cpu").items()}))
    if args.test:
        test_docs = [{"text": t, "spans": s} for t, s in load(args.test)]
        for threshold in (0.3, 0.4, 0.5, 0.6, 0.7):
            print(f"test t={threshold}:", json.dumps({k: round(v, 4) for k, v in span_scores(model, test_docs, "cpu", threshold).items()}))
        span_scores(model, test_docs, "cpu", show=25)


if __name__ == "__main__":
    main()
