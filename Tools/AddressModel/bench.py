"""Scores checkpoints on the handwritten sets the way Scrub reads text: only
the prefilter's windows, the model's spans, then the acceptance rules
AddressModel.swift applies (`accepts`). Development only.

    python bench.py --load a.pt [b.pt ...] [--old-prefilter] [--sets handwritten.txt ...] [--show]
"""
import argparse
import json
import os
import re
import sys

import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from evaluate import parse  # noqa: E402
from model import AddressModel  # noqa: E402
from prefilter import windows  # noqa: E402
from train import decode, normal, predict, quantized  # noqa: E402

DEV = ["handwritten.txt", "handwritten-final.txt", "handwritten-holdout.txt", "handwritten-business.txt",
       "handwritten-lowercase.txt", "handwritten-numberless.txt", "handwritten-multilingual.txt"]

# Places Scrub knows by name (Places.swift, AddressBlock.swift), for the lowercase rule.
SWIFT = os.environ.get("SCRUB_SOURCES", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Sources", "ScrubCore")) + "/"


def known_places():
    text = open(SWIFT + "Places.swift", encoding="utf-8").read()
    names = set()
    for table in ("us", "ca", "gb", "au"):
        body = re.search(r"private static let " + table + r' = """\n(.*?)"""', text, re.S).group(1)
        for line in body.strip().split("\n"):
            names.add(line.strip().split("|")[0].lower())
    body = re.search(r'private static let abroadTable = """\n(.*?)"""', text, re.S).group(1)
    for entry in re.split(r"[;\n]", body):
        fields = entry.strip().split("|")
        if len(fields) == 4:
            names.add(fields[1].lower())
    for m in re.finditer(r'\("(?:US|CA|AU|GB)", "([^"]+)"\)', text):
        for entry in m.group(1).split("|"):
            code, name = entry.split(" ", 1)
            names.add(name.lower())
    block = open(SWIFT + "AddressBlock.swift", encoding="utf-8").read()
    m = re.search(r'let list = "([^"]+)"', block)
    for entry in m.group(1).split("|"):
        for name in entry.split(":")[1].split(","):
            if len(name) > 2:
                names.add(name)
    return names


PLACES = known_places()
COUNTIES = {w.lower() for w in """Oxfordshire Warwickshire Gloucestershire Hertfordshire Buckinghamshire Wiltshire Somerset Dorset Devon Cornwall Cumbria Essex
Kent Surrey Suffolk Norfolk Shropshire Herefordshire Worcestershire Lincolnshire Hampshire Cambridgeshire Northumberland Derbyshire Powys Gwynedd Aberdeenshire
Perthshire Fife Argyll Lancashire Cheshire Staffordshire Leicestershire Rutland Berkshire""".split()}
KINDS = r"street|st|road|rd|lane|ln|avenue|ave|av|drive|dr|close|crescent|cres|way|place|pl|terrace|court|ct|highway|square|gardens|grove|mews|rise|walk|parade|quay|row|hill|view|green|vale|chase|wharf|boulevard|blvd|circle|trail|parkway|esplanade|yard|path|alley|loop"
LEAD = r"rue|allée|impasse|chemin|quai|route|boulevard|avenue|place|via|viale|piazza|piazzale|corso|largo|vicolo|strada|calle|c/|avenida|avda|plaza|paseo|camino|ronda|carrer|rambla|rua|travessa|praça|estrada|alameda|ul|ulica|al|aleja|lieu-dit|località"
SUFFIX = r"straße|strasse|str\.|gasse|platz|allee|ufer|damm|steig|pfad|straat|laan|gracht|plein|kade|singel|dijk|steeg|gatan|vägen|gränd|torget|gade|gaden|vej|vejen|stræde|torvet|veien|vegen|gata|katu|tie|kuja|polku|weg|ring|chaussee|stigen|backen|plan|allén|plass|bakken|stien|vænget|parken|tori|rinne|ranta"
BUILDING = r"house|cottage|lodge|farm|barn|manor|grange|mill|hall|croft|rectory|vicarage|granary|forge|stables|manse|chapel|malthouse|mansions|court|tower|building|centre|center"
UNIT = r"(?:flat|apt|apartment|unit|suite|ste|room|floor|level|appt|bâtiment|escalier|piso|wohnung|top|po box|p\.o\. box|box|postfach|postbus|bp|cs|apartado)"
STREETISH = re.compile(rf"(?i)(?:^|\s)(?:{LEAD})(?:\s|$)|\b\w+(?:{SUFFIX})\b|\b(?:{KINDS})\.?$|\b(?:{KINDS})\b(?=\s*$)")
BUILDINGISH = re.compile(rf"(?i)\b(?:{BUILDING})\b|^the\s+\w+|\b{UNIT}\s+[a-z]\b|\bground floor\b|\btop flat\b|\bbasement flat\b")
POSTCODE = re.compile(r"(?i)(?<![\w/-])(?:[a-z]\d[a-z] ?\d[a-z]\d|[a-z]{1,2}\d[a-z\d]? ?\d[a-z]{2}|[ac-fhknprtv-y]\d[\dw] ?[0-9ac-fhknprtv-y]{4}|\d{4} ?[a-z]{2}|\d{5}-\d{3,4}|\d{4}-\d{3}|\d{3}-\d{4}|\d{2}-\d{3}|\d{3} \d{2}|\d{4,6})(?![\w/-])")
UNITNUM = re.compile(rf"(?i)\b{UNIT}\.?\s*#?\s*\d")


# Words a stand-in keeps by design (kinds of street, units, countries), as the end-to-end check counts them.
KEEP = set(['africa', 'al', 'alameda', 'allée', 'apartado', 'apartment', 'apartments', 'apt', 'apto', 'australia', 'austria', 'av', 'ave', 'avenida', 'avenue', 'bajo', 'belgique', 'belgium', 'bis', 'bldg', 'blk', 'block', 'bloco', 'blvd', 'boulevard', 'box', 'brasil', 'brazil', 'building', 'bureau', 'bâtiment', 'calle', 'calz', 'canada', 'casella', 'cct', 'center', 'central', 'centre', 'cep', 'chase', 'chemin', 'cir', 'circle', 'circuit', 'city', 'close', 'col', 'corso', 'court', 'cres', 'crescent', 'cross', 'ct', 'czechia', 'da', 'danmark', 'das', 'dcha', 'de', 'dei', 'del', 'denmark', 'depto', 'des', 'deutschland', 'do', 'dos', 'dr', 'drive', 'dto', 'du', 'east', 'enclave', 'england', 'españa', 'esplanade', 'esq', 'estrada', 'farm', 'fields', 'finland', 'first', 'flat', 'floor', 'forge', 'fourth', 'france', 'gade', 'gardens', 'gate', 'germany', 'granary', 'green', 'ground', 'grove', 'highway', 'hill', 'house', 'hwy', 'iii', 'impasse', 'india', 'int', 'ireland', 'italia', 'italy', 'izq', 'japan', 'kat', 'kingdom', 'la', 'lane', 'las', 'level', 'lgh', 'ln', 'loop', 'los', 'lot', 'main', 'mansions', 'mews', 'mexico', 'méxico', 'nederland', 'netherlands', 'new', 'no', 'norge', 'north', 'norway', 'nº', 'og', 'parade', 'park', 'parkway', 'passage', 'pde', 'piazza', 'piso', 'pkwy', 'pl', 'place', 'plaza', 'plot', 'pmb', 'po', 'poland', 'polska', 'portugal', 'postale', 'postboks', 'postbus', 'postfach', 'praça', 'pza', 'quai', 'quay', 'rang', 'rd', 'residency', 'rise', 'road', 'room', 'row', 'rua', 'rue', 'sala', 'schweiz', 'scotland', 'second', 'shop', 'singapore', 'south', 'spain', 'square', 'st', 'states', 'stn', 'strada', 'strasse', 'straße', 'street', 'suite', 'suomi', 'sverige', 'sweden', 'switzerland', 'tce', 'ter', 'terrace', 'th', 'the', 'third', 'top', 'tower', 'tr', 'trail', 'travessa', 'trl', 'tv', 'u.s.a', 'uk', 'ul', 'unit', 'united', 'us', 'usa', 'vale', 'vej', 'via', 'viale', 'vicolo', 'view', 'wales', 'walk', 'way', 'weg', 'west', 'wharf', 'wohnung', 'yard', 'zealand', 'österreich'])


def pieces(text):
    return [p.strip() for p in re.split(r"[,;\n|·•]| - | – | — ", text) if p.strip()]


def known(piece):
    lower = piece.lower().strip(". ")
    if lower in PLACES or lower in COUNTIES:
        return True
    if re.match(r"(?i)^(?:co\.?|county)\s+\w+", piece):
        return True
    words = re.findall(r"[^\W\d_]+", lower)
    return any(" ".join(words[i:j]) in PLACES for i in range(len(words)) for j in range(i + 1, min(len(words), i + 4) + 1)) or any(w in COUNTIES for w in words)


def accepts(value):
    """The rules AddressModel.swift adds to the model's spans: an address with
    no number needs a street or a building and another piece beside it; one
    written all in lowercase needs a postcode, a unit or box, or a place Scrub knows."""
    digit = any(ch.isdigit() for ch in value)
    lower = not any(ch.isupper() for ch in value)
    parts = pieces(value)
    if not digit:
        if len(parts) < 2:
            return False
        streetish = [bool(STREETISH.search(p)) or bool(BUILDINGISH.search(p)) for p in parts]
        if not any(streetish):
            return False
        if lower:
            return any(known(p) for p in parts)
        others = [p for p, s in zip(parts, streetish)]
        return len(others) >= 2 and all(re.search(r"[^\W\d_]", p) for p in parts) and all(len(p.split()) <= 6 for p in parts)
    if lower:
        return bool(POSTCODE.search(value)) or bool(UNITNUM.search(value)) or any(known(p) for p in parts)
    return has_cue(value)


def has_cue(value):
    """AddressBlock.hasCue, near enough: a kind of street, a unit or box, a postcode's shape, a place Scrub knows, or 4–6 digits beside a capitalised word."""
    if STREETISH.search(value) or re.search(rf"(?i)\b(?:{KINDS}|{LEAD})\b", value) or re.search(rf"(?i)\b{UNIT}\b", value):
        return True
    if re.search(r"(?<![\w/-])(?:[A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}|\d{4} ?[A-Z]{2}|\d{5}-\d{3}|\d{4}-\d{3}|\d{3}-\d{4}|\d{2}-\d{3}|\d{3} \d{2})(?![\w/-])", value):
        return True
    words = re.findall(r"[\w'/-]+", value)
    for i, w in enumerate(words):
        if (w.upper() == w and len(w) == 2 and w.isalpha()) or known(w):
            return True
        if w.isdigit() and 4 <= len(w) <= 6 and any(0 <= j < len(words) and words[j][:1].isupper() and not any(c.isdigit() for c in words[j]) for j in (i - 1, i + 1)):
            return True
    return False


TAIL_WORDS = {"seit", "ab", "bis", "bitte", "danke", "und", "la", "le", "les", "depuis", "dès", "svp", "merci", "et", "desde", "gracias", "y", "dal", "dalla", "dopo",
              "grazie", "vanaf", "sinds", "bedankt", "en", "från", "fra", "tack", "tak", "och", "og", "from", "since", "until", "after", "before", "on", "at", "is",
              "was", "the", "and", "pls", "please", "thx", "thanks", "asap", "fyi", "for", "last", "next", "tomorrow", "today", "now", "jetzt", "nu", "not", "but",
              "so", "if", "c'est", "est", "é", "è", "es", "ist", "er", "a", "à"}


def refine_lower(text, span):
    """AddressModel.refined's rule for an address all in lowercase: it ends with
    its last piece's number or known place, and the sentence's words after go."""
    from model import tokenize
    a, b = span
    value = text[a:b]
    if any(ch.isupper() for ch in value):
        # A last piece of lowercase words alone, after a written address, is the sentence going on.
        tokens = [(a + s, a + e) for s, e in tokenize(value)]
        words = [text[s:e] for s, e in tokens]
        cut = [i for i, w in enumerate(words) if w in (",", ";", "\n")]
        if cut and cut[-1] >= 1 and all(not any(ch.isalnum() for ch in w) or (w.isalpha() and w[0].islower()) for w in words[cut[-1] + 1:]) \
                and any(w[:1].isupper() for w in words[:cut[-1]]):
            end = cut[-1] - 1
            while end > 0 and not any(ch.isalnum() for ch in words[end]):
                end -= 1
            return (a, tokens[end][1])
        return span
    tokens = [(a + s, a + e) for s, e in tokenize(value)]
    words = [text[s:e] for s, e in tokens]
    start = max([i + 1 for i, w in enumerate(words) if w in (",", ";", "\n")], default=0)
    # A last piece of the sentence's words alone (", danke") is no part of it.
    if start > 0 and all(w in TAIL_WORDS or not any(ch.isalnum() for ch in w) for w in words[start:]):
        return refine_lower(text, (a, tokens[start - 2][1])) if start >= 2 else span
    def place_end(i):
        found = []
        j = i
        while j >= start and len(found) < 3 and any(ch.isalnum() for ch in words[j]):
            found.insert(0, words[j])
            if " ".join(found).lower() in PLACES or " ".join(found).lower() in COUNTIES:
                return True
            j -= 1
        return False
    anchors = [i for i in range(start, len(words)) if any(ch.isdigit() for ch in words[i]) or place_end(i)]
    if not anchors or anchors[-1] >= len(words) - 1:
        return span
    end = anchors[-1]
    if any(ch.isdigit() for ch in words[end]):
        while end + 1 < len(words) and any(ch.isalnum() for ch in words[end + 1]) and words[end + 1] not in TAIL_WORDS and end - anchors[-1] < 3:
            end += 1
    if end < len(words) - 1 and any(w in TAIL_WORDS for w in words[end + 1:]):
        return (a, tokens[end][1])
    return span


def score(model, cases, numberless_prefilter=True, rules=True, threshold=0.5, show=False, numberless=True):
    texts, owners = [], []
    for index, case in enumerate(cases):
        for a, b in windows(case["text"], numberless_prefilter):
            texts.append(case["text"][a:b])
            owners.append((index, a))
    results = predict(model, texts, "cpu")
    found = [[] for _ in cases]
    for (index, offset), text, (tokens, probs) in zip(owners, texts, results):
        for s, e in decode(text, tokens, probs, threshold, numberless=numberless):
            if rules:
                s, e = refine_lower(text, (s, e))
            if not rules or accepts(text[s:e]):
                found[index].append((s + offset, e + offset))
    if os.environ.get("BENCH_DUMP"):
        with open(os.environ["BENCH_DUMP"], "a") as out:
            for case, spans in zip(cases, found):
                out.write(json.dumps({"text": case["text"], "found": spans}, ensure_ascii=False) + "\n")
    if os.environ.get("BENCH_UNION"):
        extra = {}
        for line in open(os.environ["BENCH_UNION"]):
            row = json.loads(line)
            extra.setdefault(row["text"], []).extend(tuple(x) for x in row["found"])
        merged = []
        for case, spans in zip(cases, found):
            together = sorted(set(map(tuple, spans)) | set(extra.get(case["text"], [])))
            joined = []
            for a, b in together:
                if joined and a < joined[-1][1]:
                    joined[-1] = (joined[-1][0], max(joined[-1][1], b))
                else:
                    joined.append((a, b))
            merged.append(joined)
        found = merged
    gold = exact = covered = negatives = false = whole = 0
    lines = []
    for case, spans in zip(cases, found):
        f = sorted({normal(case["text"], x) for x in spans})
        g = [normal(case["text"], s) for s in case["spans"]]
        gold += len(g)
        exact += len(set(f) & set(g))
        covered += sum(1 for a, b in g if any(s <= a and b <= e for s, e in f))
        # Every distinctive word inside some finding, however the address was split.
        for a, b in g:
            spots = [m.span() for m in re.finditer(r"[\w-]+", case["text"][a:b]) if len(m.group(0)) >= 2 and m.group(0).lower() not in KEEP]
            whole += all(any(s <= a + x and a + y <= e for s, e in f) for x, y in spots)
        stray = [x for x in f if not any(x[0] < b and a < x[1] for a, b in g)]
        if not g:
            negatives += 1
            false += bool(stray)
        if show and set(f) != set(g):
            t = case["text"]
            lines.append(("MISS " if g else "FALSE ") + json.dumps(t[:150], ensure_ascii=False) + "\n     gold: " + json.dumps([t[a:b] for a, b in g], ensure_ascii=False) + "\n    found: " + json.dumps([t[a:b] for a, b in f], ensure_ascii=False))
    return {"addresses": gold, "exact": exact, "covered": covered, "whole": whole, "lookalikes": negatives, "false": false}, lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", nargs="+", required=True)
    parser.add_argument("--sets", nargs="+", default=DEV)
    parser.add_argument("--old-prefilter", action="store_true")
    parser.add_argument("--old", action="store_true", help="the first model's reading before: digit lines, digit spans, no acceptance rules")
    parser.add_argument("--first", action="store_true", help="the first model's reading now: digit lines, digit spans, with the acceptance rules")
    parser.add_argument("--no-rules", action="store_true")
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    for path in args.load:
        model = AddressModel()
        model.load_state_dict(torch.load(path, map_location="cpu"))
        model.eval()
        quantized(model)
        print(f"== {os.path.basename(path)}")
        for name in args.sets:
            path = os.path.join(here, name) if not os.path.isabs(name) else name
            cases = [json.loads(l) for l in open(path)] if path.endswith(".jsonl") else parse(path)
            result, lines = score(model, cases, not (args.old_prefilter or args.old or args.first), not (args.no_rules or args.old), args.threshold, args.show, numberless=not (args.old or args.first))
            r = result
            print(f"  {name:32} exact {r['exact']:3}/{r['addresses']:<3} covered {r['covered']:3}/{r['addresses']:<3} words {r['whole']:3}/{r['addresses']:<3} false {r['false']}/{r['lookalikes']}")
            for line in lines:
                print("    " + line.replace("\n", "\n    "))


if __name__ == "__main__":
    main()
