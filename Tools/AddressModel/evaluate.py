"""Scores a checkpoint on the handwritten held-out cases (⟦…⟧ marks addresses).

    python evaluate.py --load AddressModel.bin.pt --cases ../handwritten.txt [--threshold 0.5]
"""
import argparse
import json

import torch

from model import WIDE, AddressModel
from train import decode, normal, predict, quantized


def parse(path):
    cases = []
    for block in open(path, encoding="utf-8").read().split("\n====\n"):
        lines = [l for l in block.split("\n") if not l.startswith("# ")]
        raw = "\n".join(lines).strip("\n")
        text, spans, i = "", [], 0
        while i < len(raw):
            if raw[i] == "⟦":
                start = len(text)
                end = raw.index("⟧", i)
                text += raw[i + 1:end]
                spans.append((start, len(text)))
                i = end + 1
            else:
                text += raw[i]
                i += 1
        if text.strip():
            cases.append({"text": text, "spans": spans})
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", required=True)
    parser.add_argument("--cases", required=True)
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    model = AddressModel()
    model.load_state_dict(torch.load(args.load, map_location="cpu"))
    quantized(model)
    cases = parse(args.cases)
    results = predict(model, [c["text"] for c in cases], "cpu")
    gold = exact = covered = negatives = false = 0
    for case, (tokens, probs) in zip(cases, results):
        found = [normal(case["text"], f) for f in decode(case["text"], tokens, probs, args.threshold, numberless=WIDE)]
        g = [normal(case["text"], s) for s in case["spans"]]
        gold += len(g)
        exact += len(set(found) & set(g))
        covered += sum(1 for a, b in g if any(s <= a and b <= e for s, e in found))
        stray = [f for f in found if not any(f[0] < b and a < f[1] for a, b in g)]
        if not g:
            negatives += 1
            false += bool(stray)
        ok = set(found) == set(g)
        if not ok and not args.quiet:
            t = case["text"]
            print("MISS" if g else "FALSE", json.dumps(t[:160], ensure_ascii=False))
            print("   gold :", [t[a:b] for a, b in g])
            print("   found:", [t[a:b] for a, b in found])
    print(f"addresses={gold} exact={exact / max(gold, 1):.3f} covered={covered / max(gold, 1):.3f} negatives={negatives} false_alarm_cases={false}")


if __name__ == "__main__":
    main()
