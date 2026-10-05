"""Final check only, never training or tuning: runs a checkpoint over the
evaluation corpus the way Scrub will (the prefilter's lines, two lines either
side, then the acceptance rules) and reports per set: addresses inside one
finding, addresses inside findings however split, and stray findings.

    python corpus_check.py --load v2.bin.pt --corpus ~/Work/scrub-eval-data/corpus [--show 5]
"""
import argparse
import glob
import json
import os

import torch

from bench import accepts
from model import AddressModel
from prefilter import windows
from train import decode, predict, quantized


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", required=True)
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--show", type=int, default=0)
    parser.add_argument("--old", action="store_true", help="read as the first model was: digit lines only, no numberless spans, no acceptance rules")
    parser.add_argument("--first", action="store_true", help="read as Scrub reads with the first model now: digit lines, digit spans, the acceptance rules")
    parser.add_argument("--dump", help="also write each document's findings here, for --union")
    parser.add_argument("--union", help="join these findings (another model's --dump) to this model's, as Scrub joins its two models'")
    args = parser.parse_args()
    model = AddressModel()
    model.load_state_dict(torch.load(args.load, map_location="cpu"))
    quantized(model)
    for path in sorted(glob.glob(os.path.join(args.corpus, "*.jsonl"))):
        docs = [json.loads(l) for l in open(path)]
        pieces = [(d, a, b) for d in docs for a, b in windows(d["text"], numberless=not (args.old or args.first))]
        results = predict(model, [d["text"][a:b] for d, a, b in pieces], "cpu")
        found = {}
        for (d, a, b), (tokens, probs) in zip(pieces, results):
            for s, e in decode(d["text"][a:b], tokens, probs, numberless=not (args.old or args.first)):
                if not args.old and not accepts(d["text"][a:b][s:e]):
                    continue
                found.setdefault(d["id"], []).append((a + s, a + e))
        if args.dump:
            with open(args.dump, "a") as out:
                for d in docs:
                    out.write(json.dumps({"set": os.path.basename(path), "id": d["id"], "found": found.get(d["id"], [])}) + "\n")
        if args.union:
            for line in open(args.union):
                row = json.loads(line)
                if row["set"] == os.path.basename(path):
                    found.setdefault(row["id"], []).extend(tuple(x) for x in row["found"])
            for key, spans in found.items():
                joined = []
                for a, b in sorted(set(map(tuple, spans))):
                    if joined and a < joined[-1][1]:
                        joined[-1] = (joined[-1][0], max(joined[-1][1], b))
                    else:
                        joined.append((a, b))
                found[key] = joined
        gold = covered = whole = stray = 0
        shown = 0
        for d in docs:
            spans = [(x["start"], x["end"]) for x in d["spans"] if x["label"] == "ADDRESS"]
            others = [(x["start"], x["end"]) for x in d["spans"] if x["label"] in ("ADDRESS", "LOCATION")]
            got = found.get(d["id"], [])
            gold += len(spans)
            covered += sum(1 for a, b in spans if any(s <= a and b <= e for s, e in got))
            # However the findings split it: every letter and digit inside one of them.
            whole += sum(1 for a, b in spans if all(any(s <= i < e for s, e in got) for i in range(a, b) if d["text"][i].isalnum()))
            for s, e in got:
                if not any(s < b and a < e for a, b in others):
                    stray += 1
                    if shown < args.show:
                        shown += 1
                        print(f"  stray [{os.path.basename(path)}]", json.dumps(d["text"][max(0, s - 40):e + 40], ensure_ascii=False))
        words = sum(len(d["text"].split()) for d in docs)
        print(f"{os.path.basename(path)}: docs={len(docs)} words={words} address_spans={gold} covered={covered} covered_in_parts={whole} stray_findings={stray}")


if __name__ == "__main__":
    main()
