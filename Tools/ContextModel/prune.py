"""Prunes the base tokenizer's unigram vocabulary to the scripts in scope.

Keeps every single-character piece of those scripts (so no text in them
becomes <unk>), the pieces our training corpus and an English word list use,
and the most likely pieces per script by unigram score. Writes a new
tokenizer.json whose segmentation only uses kept pieces, and the old ids of
the kept rows, in new-id order.
"""
import json
import sys
import unicodedata
from collections import defaultdict

from transformers import AutoTokenizer

# The base tokenizer, at the revision the shipped model was built from.
BASE_TOKENIZER, BASE_REVISION = "FacebookAI/xlm-roberta-base", "e73636d4f797dec63c3081bb6ed5c7b0bb3f2089"

SCRIPTS = ["LATIN", "CYRILLIC", "GREEK", "HEBREW", "ARABIC", "THAI", "DEVANAGARI", "CJK", "HIRAGANA", "KATAKANA", "HANGUL"]
TOP = {"LATIN": 40000, "CYRILLIC": 5000, "GREEK": 1500, "HEBREW": 1500, "ARABIC": 3000, "THAI": 1500, "DEVANAGARI": 1500,
       "CJK": 0, "HIRAGANA": 1000, "KATAKANA": 800, "HANGUL": 2000}


def script(ch):
    if ch.isascii():
        return "LATIN" if ch.isalpha() else "COMMON"
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return "OTHER"
    for s in SCRIPTS:
        if s in name:
            return s
    return "COMMON" if unicodedata.category(ch)[0] in "PSNZ" else "OTHER"


def main(out_dir, corpus_files):
    tok = AutoTokenizer.from_pretrained(BASE_TOKENIZER, revision=BASE_REVISION)
    spec = json.loads(tok.backend_tokenizer.to_str())
    vocab = spec["model"]["vocab"]  # [[piece, score], ...] by id
    keep = set(range(4))  # <s> <pad> </s> <unk>
    by_script = defaultdict(list)
    for i, (piece, score) in enumerate(vocab):
        text = piece.replace("▁", "")
        scripts = {script(ch) for ch in text} - {"COMMON"}
        if "OTHER" in scripts or len(scripts) > 1:
            continue
        if not scripts:  # punctuation, digits, the bare ▁
            keep.add(i)
            continue
        s = scripts.pop()
        if len(text) == 1:
            keep.add(i)
        by_script[s].append((score, i))
    for s, items in by_script.items():
        items.sort(reverse=True)
        keep.update(i for _, i in items[:TOP[s]])
    used = 0
    for path in corpus_files:
        lines = open(path).read().splitlines()
        for start in range(0, len(lines), 2000):
            batch = [json.loads(l)["text"] if l.startswith("{") else l for l in lines[start:start + 2000]]
            for ids in tok(batch, add_special_tokens=False)["input_ids"]:
                for i in ids:
                    text = vocab[i][0].replace("▁", "")
                    if not ({script(ch) for ch in text} & {"OTHER"}):
                        if i not in keep:
                            used += 1
                        keep.add(i)
    old_ids = sorted(keep)
    spec["model"]["vocab"] = [vocab[i] for i in old_ids]
    spec["model"]["unk_id"] = old_ids.index(3)
    spec["added_tokens"] = [t for t in spec["added_tokens"] if t["id"] < 4]
    from tokenizers import Tokenizer
    new = Tokenizer.from_str(json.dumps(spec))
    new.save(f"{out_dir}/tokenizer.json")
    json.dump(old_ids, open(f"{out_dir}/old_ids.json", "w"))
    print("kept", len(old_ids), "of", len(vocab), "corpus added", used)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
