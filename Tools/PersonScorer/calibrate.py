#!/usr/bin/env python3
"""Calibrates the person scorer's two thresholds: `keepFrom`, from which a
guess is replaced on its own, and `reviewFrom`, from which a guess turned
down is still put to a person in review, left as written.

It reads the rows `PersonScorerData.signals` writes (see README) and the
labelled documents they came from, keeps only held-out documents (generated:
the same 30% `fit.py` holds out; real text: all of it), and for each pair of
thresholds measures, per set:

- people missed: labelled people no detector replaced on its own;
- people left to review: of those, the ones a review finding covers;
- findings per 1,000 words: distinct names (by document and spelling) review
  would ask about, over every word of the set;
- the share of those findings that are people.

Standard library only. Never run it on the evaluation sets.
"""
import argparse
import hashlib
import json
import re
import sys

REAL = {"realt"}
WORD = re.compile(r"[^\W_]+")


def held_out(doc, share=30):
    return int(hashlib.sha256(doc.encode()).hexdigest()[:8], 16) % 100 < share


def read_rows(path):
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            values = line.rstrip("\n").split("\t")
            yield dict(zip(header, values))


def words_by_doc(path, name):
    counts = {}
    with open(path, encoding="utf-8") as f:
        for index, line in enumerate(f):
            if not line.strip():
                continue
            doc = json.loads(line)
            counts[doc.get("id") or f"{name}-{index}"] = len(WORD.findall(doc["text"]))
    return counts


def vetoed(row):
    """Turned down because something says it is no one: never asked about."""
    flag = lambda name: float(row[name]) > 0.5
    return flag("organisation") or flag("place") or flag("determiner") or flag("version") or flag("placeCue") or (flag("allCaps") and flag("oneWord"))


def overlaps(a, b):
    return a[0] < b[1] and b[0] < a[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pairs", nargs="+", help="signals.tsv=documents.jsonl")
    parser.add_argument("--keep", default="0.08,0.15,0.25")
    parser.add_argument("--review", default="0.02,0.05,0.1,0.2,0.3,0.4,0.5,0.6")
    args = parser.parse_args()
    keeps = [float(x) for x in args.keep.split(",")]
    reviews = [float(x) for x in args.review.split(",")]

    sets = {}
    for pair in args.pairs:
        tsv, jsonl = pair.split("=")
        name = jsonl.rsplit("/", 1)[-1].rsplit(".", 1)[0]
        words = words_by_doc(jsonl, name)
        real = name.startswith("realt")
        key = "realt" if real else ("gaps" if name.startswith("gaps") else "gen")
        entry = sets.setdefault(key, {"candidates": [], "gold": [], "docs": set(), "words": 0})
        # Every word of every held-out document, guessed in or not.
        entry["words"] += sum(count for doc, count in words.items() if real or held_out(doc))
        for row in read_rows(tsv):
            source = row["source"]
            if source not in REAL and not held_out(row["doc"]):
                continue
            entry["docs"].add(row["doc"])
            span = (int(row["start"]), int(row["end"]))
            if row["kind"] == "C":
                entry["candidates"].append({
                    "doc": row["doc"], "span": span, "model": row["model"], "hand": row["hand"] == "1", "p": float(row["probability"]),
                    "label": row["label"] == "1", "free": row["free"] == "1", "ordinary": row["veto"] == "1", "vetoed": vetoed(row),
                    "value": row["value"].lower()})
            elif row["label"] == "PERSON":
                entry["gold"].append({"doc": row["doc"], "span": span, "found": row["outside"] == "1"})

    print("| set | keepFrom | reviewFrom | people | missed, replaced alone | left to review | missed after review | findings / 1k words | findings that are people |")
    print("|---|---|---|---|---|---|---|---|---|")
    for key in sorted(sets):
        entry = sets[key]
        for keep in keeps:
            kept, by_doc = [], {}
            for c in entry["candidates"]:
                if c["model"] == "name":
                    c["kept"] = c["hand"] and c["p"] >= keep
                else:
                    c["kept"] = c["free"] and c["hand"] and not c["ordinary"] and c["p"] >= keep
                if c["kept"]:
                    by_doc.setdefault(c["doc"], []).append(c["span"])
            for review in reviews:
                asked = []
                for c in entry["candidates"]:
                    if c["kept"] or c["vetoed"] or c["p"] < review:
                        continue
                    if c["model"] == "name" and not c["hand"]:
                        continue
                    if c["model"] == "context" and (not c["free"] or c["ordinary"]):
                        continue
                    if any(overlaps(c["span"], s) for s in by_doc.get(c["doc"], [])):
                        continue
                    asked.append(c)
                asked_by_doc = {}
                for c in asked:
                    asked_by_doc.setdefault(c["doc"], []).append(c["span"])
                people = len(entry["gold"])
                missed = [g for g in entry["gold"] if not g["found"] and not any(overlaps(g["span"], s) for s in by_doc.get(g["doc"], []))]
                reviewed = [g for g in missed if any(overlaps(g["span"], s) for s in asked_by_doc.get(g["doc"], []))]
                findings = {(c["doc"], c["value"]) for c in asked}
                people_findings = {(c["doc"], c["value"]) for c in asked if c["label"]}
                per_k = len(findings) / max(1, entry["words"]) * 1000
                share = f"{len(people_findings) / len(findings):.0%}" if findings else "-"
                print(f"| {key} | {keep} | {review} | {people} | {len(missed)} | {len(reviewed)} | {len(missed) - len(reviewed)} | {per_k:.2f} | {share} |")
    for key in sorted(sets):
        print(f"{key}: {len(sets[key]['docs'])} held-out documents with a guess or a person, {sets[key]['words']} words", file=sys.stderr)


if __name__ == "__main__":
    main()
