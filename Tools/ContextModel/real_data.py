"""Turns the labelled real text `fetch_data.py` downloads into the context
model's training documents: {"text", "spans": [[start, end, class]], "source"}.

    python real_data.py RAW_DIR TRAIN.jsonl VALID.jsonl --eval EVAL_DIR [--share-alike] [--seed 21]

Label mapping (see README):
- a person (WNUT-17 person, Few-NERD person-*, WikiANN PER) is PERSON,
  or USERNAME when it is an @mention;
- every @mention in a post is USERNAME, tagged by the source or not;
- a place (WNUT-17 location, Few-NERD location-*, WikiANN LOC) is LOCATION;
- an organisation (WNUT-17 corporation and group, Few-NERD
  organization-* and building-*, WikiANN ORG) is ORG only where the sentence
  speaks of someone's work ("works at", "manager", "hired"), as Scrub's own
  employer rule reads it; elsewhere it is no label, as a vendor is in the
  generated text;
- everything else (products, creative works, events, other) is no label.

Names and places the benchmarks use are held out: a document is dropped when
a labelled value has a word of NameGaps or PIIGaps in it. With --share-alike,
some English sentences also get a non-Latin name from WikiANN in place of
their person, so the model reads real names in other scripts inside English
text, and as many get an ordinary non-Latin word (one WikiANN leaves
unlabelled) in place of an English word, with no label, so a script alone
does not make a name.
"""
import argparse
import collections
import hashlib
import json
import os
import random
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "NameModel"))
import generate as g  # noqa: E402
from dedupe import Index  # noqa: E402

# ContextStage.swift's `work` pattern, without its loosest cue ("as a …", which
# reads "as a result" too): the sentence ties an organisation to someone's job.
WORK = re.compile(r"(?i)\b(?:work(?:s|ed|ing)?\s+(?:at|for)|job|employ\w*|manager|boss|colleague|payroll|redundan\w*|quit|shifts?|hired|intern\w*|trained|"
                  r"volunteer\w*|contract(?:ed|or)|ceo|cfo|cto|founder|director|officer|editor|staff|been with|started at|on the payroll)\b")
NONLATIN_LANGS = ["ru", "el", "he", "ar", "hi", "ja", "zh", "ko"]
# WikiANN's Thai labels are mostly wrong (common words tagged as people), so Thai is left out.
WIKIANN_COUNTS = {"en": 8000, "ru": 2500, "el": 2000, "he": 2000, "ar": 2500, "hi": 2000, "ja": 2000, "zh": 2000, "ko": 2000, "tr": 3000, "pl": 3000}
NO_SPACE = {"ja", "zh"}
QUOTES = {"``": '"', "''": '"', "-LRB-": "(", "-RRB-": ")"}
# WikiANN fragments that are a redirect page's title, and its leftover list and quote markup.
REDIRECT = re.compile(r"^(?:REDIRECT|ΑΝΑΚΑΤΕΥΘΥΝΣΗ|ПЕРЕНАПРАВЛЕНИЕ|تحويل|הפניה|YÖNLENDİR\w*|PATRZ|ARTYKUŁ|अनुप्रेषित|転送|重定向|넘겨주기)\b", re.I)
MARKUP = {"'", "''", "'''", "#", "*", "**", "***", ";", ":", "|"}
# A name in another script, its words joined by spaces or middle dots.
SCRIPT_NAME = re.compile(r"^[^\W\d_]+(?:[ ·・][^\W\d_]+){0,3}$")
KOREAN_PARTICLE = re.compile(r"(?:가|는|를|의|도|에게|와|과|을|에서|로)$")


def held_out():
    """Words the generated benchmarks use as names, towns, companies and non-Latin names."""
    words = set(g.held_out_vocabulary())
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Tests", "ScrubCoreTests", "PIIGaps", "PIIGapCases.swift")
    for literal in re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', open(source).read()):
        if "\\(" in literal:
            continue
        for word in re.findall(r"[^\W\d_][\w'’-]*", literal):
            if word[0].isupper() or not word.isascii():
                words.add(word.lower())
    # Titles, initials and ordinary words ("Mr", "J", "of", "Court") are in the
    # benchmarks' sentences too, but are no one's name: only the names count.
    common = set(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "common-words.txt")).read().split())
    return {w for w in words if len(w) >= 3 and w not in common and w not in {"mrs", "sir", "dr", "prof"}}


def detokenize(tokens, no_space=False):
    """Tokens joined as typed: no space before closing punctuation or after an
    opening one, "@ user" as "@user". Returns the text and each token's start."""
    text, starts = "", []
    tokens = [QUOTES.get(t, t) for t in tokens] if not no_space else tokens
    for i, token in enumerate(tokens):
        if no_space:
            token = " " if token == "#" else token
            starts.append(len(text)); text += token
            continue
        prev = tokens[i - 1] if i else ""
        glue = (not text or token in {",", ".", "!", "?", ";", ":", ")", "]", "}", "%", "'s", "n't", "'m", "'re", "'ve", "'ll", "'d", "...", "…"}
                or prev in {"(", "[", "{", "@", "#", "$"} or (prev == "'" and i >= 2 and tokens[i - 2] == "'"))
        if not glue:
            text += " "
        starts.append(len(text))
        text += token
    return text, starts


def spans_from_bio(tokens, tags, starts):
    """(start, end, type) for each B/I run; I without a B starts a run."""
    out, current = [], None
    for i, tag in enumerate(tags):
        if tag == "O" or not tag:
            current = None
            continue
        prefix, kind = tag.split("-", 1)
        end = starts[i] + len(tokens[i])
        if prefix == "I" and current and current[2] == kind:
            current[1] = end
        else:
            current = [starts[i], end, kind]
            out.append(current)
    return [tuple(s) for s in out]


def mapped(text, raw_spans, mapping, social):
    """Our classes from a source's, with the employer rule and @mentions. A
    hashtag is no one's: Scrub leaves hashtags alone."""
    joined = []
    for start, end, kind in raw_spans:
        # An "@" or "#" the source tokenised apart from its name: "@ maria".
        if joined and joined[-1][1] == start and text[joined[-1][0]:joined[-1][1]] in {"@", "#"}:
            joined[-1] = (joined[-1][0], end, kind)
        else:
            joined.append((start, end, kind))
    spans = []
    for start, end, kind in joined:
        value = text[start:end]
        if value.startswith("#"):
            continue
        cls = mapping.get(kind)
        if cls == "PERSON" and value.startswith("@"):
            cls = "USERNAME"
        if cls == "ORG":
            around = text[:start] + " " * (end - start) + text[end:]
            cls = "ORG" if WORK.search(around) else None
        if cls and value.strip():
            spans.append([start, end, cls])
    if social:
        taken = [(s, e) for s, e, _ in spans]
        for match in re.finditer(r"(?<![\w@])@\w{2,}", text):
            if not any(s < match.end() and match.start() < e for s, e in taken):
                spans.append([match.start(), match.end(), "USERNAME"])
    return sorted(spans)


def conll(path):
    sentence = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip():
            if sentence:
                yield sentence
            sentence = []
            continue
        token, tag = line.split("\t") if "\t" in line else line.rsplit(" ", 1)
        sentence.append((token, tag))
    if sentence:
        yield sentence


def from_conll(path, mapping, source):
    docs = []
    for sentence in conll(path):
        tokens, tags = [t for t, _ in sentence], [t for _, t in sentence]
        text, starts = detokenize(tokens)
        docs.append({"text": text, "spans": mapped(text, spans_from_bio(tokens, tags, starts), mapping, True), "source": source})
    return docs


def parquet_rows(path):
    import pyarrow.parquet as pq
    table = pq.read_table(path)
    names = json.loads(table.schema.metadata[b"huggingface"])["info"]["features"]
    return table.to_pylist(), names


def few_nerd(path, rng, count):
    rows, features = parquet_rows(path)
    fine = features["fine_ner_tags"]["feature"]["names"]
    docs = []
    for row in rng.sample(rows, len(rows)):
        tags, kinds = [], [fine[t] for t in row["fine_ner_tags"]]
        for i, kind in enumerate(kinds):
            tags.append("O" if kind == "O" else ("I-" if i and kinds[i - 1] == kind else "B-") + kind.split("-")[0])
        text, starts = detokenize(row["tokens"])
        mapping = {"person": "PERSON", "location": "LOCATION", "organization": "ORG", "building": "ORG"}
        docs.append({"text": text, "spans": mapped(text, spans_from_bio(row["tokens"], tags, starts), mapping, False), "source": "few-nerd"})
    # Most of Few-NERD's sentences name something; keep the share without a label it has, and take `count`.
    return docs[:count]


def wikiann(raw, lang, rng, count):
    rows, features = parquet_rows(os.path.join(raw, f"wikiann-{lang}-train.parquet"))
    names = features["ner_tags"]["feature"]["names"]
    docs = []
    for row in rng.sample(rows, len(rows)):
        tokens = row["tokens"]
        if not tokens or REDIRECT.match(tokens[0]):
            continue
        # Wikipedia markup left in the fragments: lone quotes, list stars and hashes.
        if lang not in NO_SPACE:
            keep = [i for i, t in enumerate(tokens) if t not in MARKUP]
            tokens, tags = [tokens[i] for i in keep], [names[row["ner_tags"][i]] for i in keep]
        else:
            tags = [names[t] for t in row["ner_tags"]]
        if not tokens:
            continue
        text, starts = detokenize(tokens, no_space=lang in NO_SPACE)
        spans = mapped(text, spans_from_bio(tokens, tags, starts), {"PER": "PERSON", "LOC": "LOCATION", "ORG": "ORG"}, False)
        stripped = text.strip()
        if not stripped:
            continue
        shift = len(text) - len(text.lstrip())
        spans = [[s - shift, e - shift, c] for s, e, c in spans if text[s:e].strip()]
        docs.append({"text": stripped, "spans": spans, "source": f"wikiann-{lang}"})
        if len(docs) == count:
            break
    return docs


def nonlatin_names(raw, rng, avoid):
    """People's names from WikiANN in the scripts Scrub reads names in."""
    names = collections.defaultdict(list)
    for lang in NONLATIN_LANGS:
        rows, features = parquet_rows(os.path.join(raw, f"wikiann-{lang}-train.parquet"))
        labels = features["ner_tags"]["feature"]["names"]
        for row in rows:
            text, starts = detokenize(row["tokens"], no_space=lang in NO_SPACE)
            for s, e, kind in spans_from_bio(row["tokens"], [labels[t] for t in row["ner_tags"]], starts):
                value = text[s:e].strip()
                if kind == "PER" and 2 <= len(value) <= 24 and SCRIPT_NAME.match(value) and not any(ch.isascii() for ch in value.replace(" ", "")) \
                        and not (lang == "ko" and KOREAN_PARTICLE.search(value)) and not any(w.lower() in avoid for w in value.split()):
                    names[lang].append(value)
    return {lang: sorted(set(v)) for lang, v in names.items()}


def code_switched(docs, names, rng, count):
    """English sentences with one person swapped for a non-Latin name."""
    out = []
    pool = [d for d in docs if any(c == "PERSON" for _, _, c in d["spans"]) and d["source"] in {"wnut17", "few-nerd"}]
    for doc in rng.sample(pool, min(count, len(pool))):
        persons = [s for s in doc["spans"] if s[2] == "PERSON"]
        start, end, _ = rng.choice(persons)
        name = rng.choice(names[rng.choice(sorted(names))])
        text = doc["text"][:start] + name + doc["text"][end:]
        shift = len(name) - (end - start)
        spans = [[s, e, c] if e <= start else [s + shift, e + shift, c] for s, e, c in doc["spans"] if (s, e) != (start, end)]
        spans.append([start, start + len(name), "PERSON"])
        out.append({"text": text, "spans": sorted(spans), "source": "code-switch"})
    return out


def nonlatin_words(raw, rng):
    """Ordinary words from WikiANN's non-Latin sentences: runs its labels leave unnamed."""
    words = collections.defaultdict(set)
    for lang in NONLATIN_LANGS:
        rows, features = parquet_rows(os.path.join(raw, f"wikiann-{lang}-train.parquet"))
        labels = features["ner_tags"]["feature"]["names"]
        for row in rows:
            tokens, tags = row["tokens"], [labels[t] for t in row["ner_tags"]]
            if any(t != "O" for t in tags) and lang in NO_SPACE:
                continue
            plain = [t for t, tag in zip(tokens, tags) if tag == "O" and re.fullmatch(r"[^\W\d_]+", t) and not t.isascii()]
            if lang in NO_SPACE:
                run = "".join(plain)
                for _ in range(2):
                    if len(run) >= 2:
                        size = rng.randint(2, min(4, len(run)))
                        at = rng.randrange(len(run) - size + 1)
                        words[lang].add(run[at:at + size])
            else:
                words[lang].update(w for w in plain if len(w) >= 3)
    return {lang: sorted(v) for lang, v in words.items()}


def code_switched_words(docs, words, rng, count):
    """English sentences with one ordinary word swapped for a word in another
    script, with no label: a script alone does not make a name."""
    out = []
    pool = [d for d in docs if d["source"] in {"wnut17", "few-nerd"}]
    for doc in rng.sample(pool, min(count, len(pool))):
        text = doc["text"]
        free = [m for m in re.finditer(r"\b[a-z]{3,}\b", text) if not any(s < m.end() and m.start() < e for s, e, _ in doc["spans"])]
        if not free:
            continue
        m = rng.choice(free)
        word = rng.choice(words[rng.choice(sorted(words))])
        shift = len(word) - (m.end() - m.start())
        spans = [[s, e, c] if e <= m.start() else [s + shift, e + shift, c] for s, e, c in doc["spans"]]
        out.append({"text": text[:m.start()] + word + text[m.end():], "spans": spans, "source": "code-switch-word"})
    return out


BORN = re.compile(r"(?i)\bborn(?:\s+(?:on|in))?\s*$")


def tab(path):
    """Court judgments from the Text Anonymization Benchmark's training split,
    one document a paragraph, labelled by the first annotator (by name) of each
    judgment, as Scrub's evaluation reads its dev and test splits:
    - PERSON, any identifier type, is PERSON (a name is a name);
    - LOC and CODE marked DIRECT or QUASI are LOCATION and ID; marked NO_MASK
      (countries, the court's own references) they are no label;
    - DATETIME right after "born", "born on" or "born in" is DOB, otherwise no label;
    - ORG is ORG only where the sentence speaks of someone's work;
    - DEM, MISC and QUANTITY are no label.
    Judgments share wording, so the evaluation check (dedupe.py) drops
    paragraphs, not whole judgments."""
    docs = []
    for judgment in json.load(open(path)):
        text = judgment["text"]
        mentions = judgment["annotations"][sorted(judgment["annotations"])[0]]["entity_mentions"]
        raw = []
        for m in mentions:
            kind, identifier, start, end = m["entity_type"], m["identifier_type"], m["start_offset"], m["end_offset"]
            if kind == "PERSON":
                raw.append((start, end, "PER"))
            elif kind in ("LOC", "CODE") and identifier in ("DIRECT", "QUASI"):
                raw.append((start, end, kind))
            elif kind == "DATETIME" and BORN.search(text[max(0, start - 20):start]):
                raw.append((start, end, "DOB"))
            elif kind == "ORG":
                raw.append((start, end, "ORG"))
        start = 0
        for part in re.split(r"(\n\s*\n)", text):
            end = start + len(part)
            if part.strip() and not re.fullmatch(r"\n\s*\n", part):
                inside = [(s - start, e - start, k) for s, e, k in raw if start <= s and e <= end]
                spans = mapped(part, sorted(set(inside)), {"PER": "PERSON", "LOC": "LOCATION", "CODE": "ID", "DOB": "DOB", "ORG": "ORG"}, False)
                docs.append({"text": part, "spans": spans, "source": "tab"})
            start = end
    return docs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("raw")
    parser.add_argument("out")
    parser.add_argument("valid", help="where the 3% held out for validation goes")
    parser.add_argument("--share-alike", action="store_true")
    parser.add_argument("--tab", action="store_true", help="add the Text Anonymization Benchmark's training split (MIT)")
    parser.add_argument("--seed", type=int, default=21)
    parser.add_argument("--few-nerd", type=int, default=25000)
    parser.add_argument("--code-switch", type=int, default=5000)
    parser.add_argument("--eval", required=True, help="the real-text evaluation folder: matching text is dropped (dedupe.py)")
    args = parser.parse_args()
    rng = random.Random(args.seed)
    avoid = held_out()
    docs = from_conll(os.path.join(args.raw, "wnut17train.conll"),
                      {"person": "PERSON", "location": "LOCATION", "corporation": "ORG", "group": "ORG"}, "wnut17")
    if args.tab:
        docs += tab(os.path.join(args.raw, "echr_train.json"))
    if args.share_alike:
        docs += few_nerd(os.path.join(args.raw, "few-nerd-train.parquet"), rng, args.few_nerd)
        for lang, count in WIKIANN_COUNTS.items():
            docs += wikiann(args.raw, lang, rng, count)
    index = Index(args.eval)
    kept, dropped, matched = [], collections.Counter(), collections.Counter()

    def admit(doc):
        if not doc["text"].strip():
            return
        if any(re.sub(r"[^\w'’-]", "", w).lower() in avoid for s, e, _ in doc["spans"] for w in doc["text"][s:e].split()):
            dropped[doc["source"]] += 1
            return
        why = index.reason(doc["text"])
        if why:
            matched[f"{doc['source']} {why}"] += 1
            return
        kept.append(doc)

    for doc in docs:
        admit(doc)
    if args.share_alike:
        # Built from sentences already cleared of the evaluation text, and checked again.
        carriers = list(kept)
        for doc in code_switched(carriers, nonlatin_names(args.raw, rng, avoid), rng, args.code_switch):
            admit(doc)
        for doc in code_switched_words(carriers, nonlatin_words(args.raw, rng), rng, args.code_switch):
            admit(doc)
    # A fixed 3% by the text's hash validates training; the same text lands on the same side in every run.
    def held(doc):
        return int.from_bytes(hashlib.blake2b(doc["text"].encode("utf-8"), digest_size=4).digest(), "little") % 100 < 3

    with open(args.out, "w") as f, open(args.valid, "w") as v:
        for doc in kept:
            (v if held(doc) else f).write(json.dumps(doc, ensure_ascii=False) + "\n")
    counts = collections.Counter(d["source"] for d in kept)
    labels = collections.Counter((d["source"], c) for d in kept for _, _, c in d["spans"])
    print(json.dumps({"documents": counts, "held_out_dropped": dropped, "evaluation_matches_dropped": matched,
                      "spans": {f"{s} {c}": n for (s, c), n in sorted(labels.items())}}, indent=1))


if __name__ == "__main__":
    main()
