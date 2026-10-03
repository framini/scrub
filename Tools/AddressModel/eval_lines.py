"""Word 8-grams of every held-out evaluation text, so generated data can be deduped against them."""
import glob
import json
import os
import re

def norm(line):
    return re.sub(r"\s+", " ", line).strip().lower()

def grams(text, n=8):
    words = re.findall(r"\w+", text.lower())
    return {" ".join(words[i:i + n]) for i in range(len(words) - n + 1)}

EVAL = os.environ.get("SCRUB_EVAL_DATA", os.path.expanduser("~/Work/scrub-eval-data"))


def eval_grams(root=EVAL):
    if not os.path.isdir(root):
        raise SystemExit(f"{root} is missing: set SCRUB_EVAL_DATA to the evaluation corpus, so generated text can be kept apart from it")
    found = set()
    for path in glob.glob(root + "/corpus/*.jsonl") + glob.glob(root + "/fresh/*.jsonl"):
        for row in open(path):
            found |= grams(json.loads(row)["text"])
    return found

def eval_lines(root=EVAL):
    lines = set()
    for path in glob.glob(root + "/corpus/*.jsonl") + glob.glob(root + "/fresh/*.jsonl"):
        for row in open(path):
            for line in json.loads(row)["text"].splitlines():
                n = norm(line)
                if len(n) >= 20:
                    lines.add(n)
    return lines
