"""Development measurement only, never training: runs a checkpoint over the
old evaluation corpus the way Scrub will (lines with a digit and a word, two
lines either side) and reports address recall and stray findings per set.

    python corpus_check.py --load v2.bin.pt --corpus ~/Work/scrub-eval-data/corpus [--show 5]
"""
import argparse
import glob
import json
import os
import re

import torch

from model import AddressModel
from train import decode, predict, quantized


def windows(text):
    lines, start = [], 0
    for match in re.finditer(r"[^\n]*\n|[^\n]+$", text):
        line = match.group(0)
        candidate = bool(re.search(r"[0-9]", line)) and bool(re.search(r"[^\W\d_]{2}", line))
        lines.append((match.start(), match.end(), candidate))
    result = []
    for index, (s, e, c) in enumerate(lines):
        if not c:
            continue
        a, b = lines[max(0, index - 2)][0], lines[min(len(lines) - 1, index + 2)][1]
        if result and result[-1][1] >= a:
            result[-1] = (result[-1][0], max(result[-1][1], b))
        else:
            result.append((a, b))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", required=True)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--show", type=int, default=0)
    args = parser.parse_args()
    model = AddressModel()
    model.load_state_dict(torch.load(args.load, map_location="cpu"))
    quantized(model)
    for path in sorted(glob.glob(os.path.join(args.corpus, "*.jsonl"))):
        docs = [json.loads(l) for l in open(path)]
        pieces = [(d, a, b) for d in docs for a, b in windows(d["text"])]
        results = predict(model, [d["text"][a:b] for d, a, b in pieces], "cpu")
        found = {}
        for (d, a, b), (tokens, probs) in zip(pieces, results):
            for s, e in decode(d["text"][a:b], tokens, probs):
                found.setdefault(d["id"], []).append((a + s, a + e))
        gold = covered = stray = 0
        shown = 0
        for d in docs:
            spans = [(x["start"], x["end"]) for x in d["spans"] if x["label"] == "ADDRESS"]
            others = [(x["start"], x["end"]) for x in d["spans"] if x["label"] in ("ADDRESS", "LOCATION")]
            got = found.get(d["id"], [])
            gold += len(spans)
            covered += sum(1 for a, b in spans if any(s <= a and b <= e for s, e in got))
            for s, e in got:
                if not any(s < b and a < e for a, b in others):
                    stray += 1
                    if shown < args.show:
                        shown += 1
                        print(f"  stray [{os.path.basename(path)}]", json.dumps(d["text"][max(0, s - 40):e + 40], ensure_ascii=False))
        words = sum(len(d["text"].split()) for d in docs)
        print(f"{os.path.basename(path)}: docs={len(docs)} words={words} address_spans={gold} covered={covered} stray_findings={stray}")


if __name__ == "__main__":
    main()
