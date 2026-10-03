"""Drops training text that matches any text Scrub is evaluated on.

    python dedupe.py EVAL_DIR IN OUT [IN OUT ...] [--report report.json]

EVAL_DIR is the real-text evaluation folder (its `corpus/` and `fresh/` JSONL
sets). IN is a training JSONL ({"text", ...} a line) or a plain text file of
lines (the man-page prose). A training text is dropped when:

- exact: it equals an evaluation text;
- normalised: it equals one after normalising both (NFKC, case folded, links
  removed, punctuation and spacing collapsed);
- sentence: one of its sentences of 20 or more normalised characters equals
  an evaluation sentence;
- overlap: it shares a run of 10 words with an evaluation text, or, when it
  has 6 to 9 words, all of them appear in that order in one.

Evaluation text is only read and hashed here; nothing of it is written out.
"""
import argparse
import collections
import glob
import hashlib
import json
import os
import re
import unicodedata

LINK = re.compile(r"(?i)\b(?:https?://|www\.)\S+")
SENTENCE = re.compile(r"(?<=[.!?。！？])\s+|\n+")
RUN = 10


def normal(text):
    text = LINK.sub(" ", unicodedata.normalize("NFKC", text)).casefold()
    return " ".join(re.sub(r"[^\w]+", " ", text).split())


def key(text):
    return hashlib.blake2b(text.encode("utf-8"), digest_size=12).digest()


def sentences(text):
    return [n for n in (normal(s) for s in SENTENCE.split(text)) if len(n) >= 20]


def runs(words, size):
    return {key(" ".join(words[i:i + size])) for i in range(len(words) - size + 1)}


class Index:
    def __init__(self, eval_dir):
        self.exact, self.normal, self.sentence = set(), set(), set()
        self.runs = {size: set() for size in range(6, RUN + 1)}
        self.texts = 0
        for path in sorted(glob.glob(os.path.join(eval_dir, "corpus", "*.jsonl")) + glob.glob(os.path.join(eval_dir, "fresh", "*.jsonl"))):
            for line in open(path, encoding="utf-8"):
                if not line.strip():
                    continue
                text = json.loads(line)["text"]
                self.texts += 1
                self.exact.add(key(text.strip()))
                n = normal(text)
                self.normal.add(key(n))
                self.sentence.update(key(s) for s in sentences(text))
                words = n.split()
                for size in self.runs:
                    self.runs[size] |= runs(words, size)

    def reason(self, text):
        if key(text.strip()) in self.exact:
            return "exact"
        n = normal(text)
        if n and key(n) in self.normal:
            return "normalised"
        if any(key(s) in self.sentence for s in sentences(text)):
            return "sentence"
        words = n.split()
        if len(words) >= RUN and runs(words, RUN) & self.runs[RUN]:
            return "overlap"
        if 6 <= len(words) < RUN and key(" ".join(words)) in self.runs[len(words)]:
            return "overlap"
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("eval_dir")
    parser.add_argument("pairs", nargs="+", help="IN OUT pairs")
    parser.add_argument("--report")
    args = parser.parse_args()
    assert len(args.pairs) % 2 == 0, "give IN OUT pairs"
    index = Index(args.eval_dir)
    report = {"evaluation_texts": index.texts, "files": {}}
    for src, dst in zip(args.pairs[::2], args.pairs[1::2]):
        removed, kept, by_source = collections.Counter(), 0, collections.Counter()
        with open(src, encoding="utf-8") as f, open(dst, "w", encoding="utf-8") as out:
            for line in f:
                if not line.strip():
                    continue
                is_json = line.startswith("{")
                record = json.loads(line) if is_json else None
                why = index.reason(record["text"] if is_json else line.rstrip("\n"))
                if why:
                    removed[why] += 1
                    by_source[(record or {}).get("source", "generated" if is_json else "prose")] += 1
                    continue
                kept += 1
                out.write(line if line.endswith("\n") else line + "\n")
        report["files"][os.path.basename(src)] = {"kept": kept, "removed": sum(removed.values()), "by_reason": dict(removed), "by_source": dict(by_source)}
        print(os.path.basename(src), json.dumps(report["files"][os.path.basename(src)]), flush=True)
    if args.report:
        json.dump(report, open(args.report, "w"), indent=1)


if __name__ == "__main__":
    main()
