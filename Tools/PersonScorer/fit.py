"""Fits the person scorer: a logistic regression over the signals Scrub
knows about a person only a model read (Sources/ScrubCore/PersonScorer.swift).

Reads the rows `PersonScorerData.signals` writes (one per guess, one per
labelled person), splits documents into a fitting part and a held-out part
by a hash of their id, fits on the first, and compares the fitted scorer
with the hand rules on the second. Prints the coefficients as Swift.

Standard library only. Never give it the real-text evaluation sets.

    python3 fit.py sig-gen-41.tsv sig-gen-valid-final.tsv sig-realt-valid.tsv sig-gaps-9001.tsv
"""
import argparse
import collections
import csv
import hashlib
import math
import sys

FEATURES = ["nameModel", "nameModelFound", "context", "contextFound",
            "first", "surname", "wordlike", "ordinary", "unknownCapital",
            "title", "greeting", "strong", "position", "subject",
            "capitalised", "lowercase", "allCaps", "oneWord", "threeWords", "opens",
            "organisation", "place", "determiner", "version", "placeCue"]


def load(paths):
    guesses, people = [], []
    for path in paths:
        with open(path, newline="") as handle:
            for row in csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE):
                if row["kind"] == "C":
                    row["x"] = [float(row[name]) for name in FEATURES]
                    guesses.append(row)
                else:
                    people.append(row)
    return guesses, people


def held_out(doc, share):
    """A stable tenth-by-tenth split of documents by their id."""
    return int(hashlib.sha256(doc.encode()).hexdigest()[:8], 16) % 100 < share


def sigmoid(z):
    return 1 / (1 + math.exp(-z)) if z > -60 else 0.0


def solve(matrix, vector):
    """Gauss-Jordan elimination with partial pivoting."""
    n = len(vector)
    a = [row[:] + [vector[i]] for i, row in enumerate(matrix)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(a[r][col]))
        a[col], a[pivot] = a[pivot], a[col]
        for r in range(n):
            if r != col and a[r][col] != 0:
                factor = a[r][col] / a[col][col]
                a[r] = [x - factor * y for x, y in zip(a[r], a[col])]
    return [a[i][n] / a[i][i] for i in range(n)]


def fit(rows, l2, iterations=30):
    """Newton's method on the weighted log-loss with an L2 penalty (not on the bias)."""
    size = len(FEATURES) + 1
    w = [0.0] * size
    for _ in range(iterations):
        gradient = [0.0] * size
        hessian = [[0.0] * size for _ in range(size)]
        for x, y, weight in rows:
            v = [1.0] + x
            p = sigmoid(sum(a * b for a, b in zip(w, v)))
            g = (p - y) * weight
            h = p * (1 - p) * weight
            for i in range(size):
                gradient[i] += g * v[i]
                if v[i] == 0:
                    continue
                hv = h * v[i]
                row = hessian[i]
                for j in range(size):
                    row[j] += hv * v[j]
        for i in range(1, size):
            gradient[i] += l2 * w[i]
            hessian[i][i] += l2
        step = solve(hessian, gradient)
        w = [a - b for a, b in zip(w, step)]
        if max(abs(s) for s in step) < 1e-7:
            break
    return w


def probability(w, x):
    return sigmoid(w[0] + sum(a * b for a, b in zip(w[1:], x)))


def evaluate(guesses, people, keep):
    """What a decision rule adds over the other detectors: labelled people
    caught (by another detector or a kept guess), and guesses kept on words
    no label covers, as distinct guesses and as words."""
    kept = collections.defaultdict(list)
    seen = set()
    false_guesses = false_words = true_guesses = 0
    for row in guesses:
        if row["free"] != "1" or not keep(row):
            continue
        key = (row["doc"], row["start"], row["end"])
        if key in seen:
            continue
        seen.add(key)
        kept[row["doc"]].append((int(row["start"]), int(row["end"])))
        if row["label"] == "1":
            true_guesses += 1
        else:
            false_guesses += 1
        false_words += int(row["outside"])
    caught = 0
    for person in people:
        start, end = int(person["start"]), int(person["end"])
        if person["outside"] == "1" or any(s < end and start < e for s, e in kept[person["doc"]]):
            caught += 1
    return {"people": len(people), "caught": caught, "kept": true_guesses + false_guesses, "false": false_guesses, "falseWords": false_words}


def feature(row, name):
    return row["x"][FEATURES.index(name)]


def agrees(row):
    """`PersonScorer.agrees`: something independent of the context model
    marks the guess as a name, and nothing marks it as an organisation, a
    place or a thing."""
    if feature(row, "organisation") or feature(row, "place") or (feature(row, "allCaps") and feature(row, "oneWord")) or feature(row, "determiner") or feature(row, "version") or feature(row, "placeCue"):
        return False
    model = bool(feature(row, "nameModelFound"))
    listed = (feature(row, "first") or feature(row, "surname")) and not feature(row, "ordinary")
    marked = feature(row, "title") or feature(row, "greeting") or feature(row, "strong")
    if feature(row, "opens") and feature(row, "subject") and feature(row, "oneWord") and not marked:
        return model
    if feature(row, "lowercase") and feature(row, "oneWord"):
        return bool(model or listed or feature(row, "title") or feature(row, "greeting"))
    cue = feature(row, "position") and not (feature(row, "opens") and feature(row, "subject") and not feature(row, "first")
                                            and not feature(row, "surname") and not feature(row, "wordlike"))
    return bool(model or listed or marked or cue)


def judged(row):
    """The guesses either rule may keep: the name model's, and the context
    model's that something agrees with. Neither keeps an ordinary-word guess."""
    return row["veto"] == "0" and (row["model"] == "name" or agrees(row))


def hand(row):
    """The hand rules: every guess `judged` lets through."""
    return judged(row)


def report(name, result):
    share = result["caught"] / max(1, result["people"]) * 100
    return f"{name:<28} caught {result['caught']:>6}/{result['people']:<6} ({share:5.1f}%)  kept {result['kept']:>5}  false {result['false']:>5}  false words {result['falseWords']:>5}"


REAL = {"tab", "wnut17"}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tsv", nargs="+")
    parser.add_argument("--held-out", type=int, default=30, help="percent of generated documents held out; real text is always held out")
    parser.add_argument("--l2", type=float, default=1.0)
    args = parser.parse_args()

    guesses, people = load(args.tsv)
    for row in guesses + people:
        row["heldOut"] = row["source"] in REAL or held_out(row["doc"], args.held_out)
    fit_guesses = [r for r in guesses if not r["heldOut"]]
    fit_people = [r for r in people if not r["heldOut"]]
    # One row per distinct guess: the two models often read the same words.
    distinct = {}
    for r in fit_guesses:
        if r["free"] == "1" and judged(r):
            distinct.setdefault((r["doc"], r["start"], r["end"]), r)
    data = [(r["x"], float(r["label"]), 1.0) for r in distinct.values()]
    print(f"fitting on {len(data)} distinct guesses ({sum(d[1] for d in data):.0f} people) in {len(set(r['doc'] for r in fit_guesses))} documents", file=sys.stderr)
    w = fit(data, args.l2)

    def learned(threshold):
        return lambda row: judged(row) and probability(w, row["x"]) >= threshold

    # The threshold: on the fitting part, as many people as the hand rules
    # catch or more, then as few words changed outside them as that allows.
    limit = evaluate(fit_guesses, fit_people, hand)
    best = None
    for step in range(2, 96):
        threshold = step / 100
        result = evaluate(fit_guesses, fit_people, learned(threshold))
        if result["falseWords"] > limit["falseWords"] or result["caught"] < limit["caught"]:
            continue
        if best is None or result["falseWords"] < best[1]["falseWords"]:
            best = (threshold, result)
    threshold = best[0] if best else 0.5

    print("\n== fitting part")
    print(report("hand rules", evaluate(fit_guesses, fit_people, hand)))
    print(report(f"scorer at {threshold:.2f}", evaluate(fit_guesses, fit_people, learned(threshold))))
    held_guesses = [r for r in guesses if r["heldOut"]]
    held_people = [r for r in people if r["heldOut"]]
    print("\n== held out (generated: a share of documents; real text: all of it)")
    for source in sorted(set(r["source"] for r in held_people)):
        g = [r for r in held_guesses if r["source"] == source]
        p = [r for r in held_people if r["source"] == source]
        print(report(f"{source}: hand rules", evaluate(g, p, hand)))
        print(report(f"{source}: scorer {threshold:.2f}", evaluate(g, p, learned(threshold))))

    # Calibration, for the confidence a kept guess carries into review.
    for name, group in [("real", lambda r: r["source"] in REAL), ("generated", lambda r: r["source"] not in REAL)]:
        print(f"\n== held-out calibration, {name} text (probability: guesses, share that are people)")
        bands = collections.defaultdict(lambda: [0, 0])
        for r in held_guesses:
            if r["free"] == "1" and judged(r) and group(r):
                band = min(9, int(probability(w, r["x"]) * 10))
                bands[band][0] += 1
                bands[band][1] += int(r["label"])
        for band in sorted(bands):
            n, positive = bands[band]
            print(f"  {band / 10:.1f}-{(band + 1) / 10:.1f}: {n:>5}  {positive / n * 100:5.1f}%")

    print("\n// Swift, for PersonScorer")
    print(f"static let bias = {w[0]:.4f}")
    print("static let weights: [Double] = [" + ", ".join(f"{v:.4f}" for v in w[1:]) + "]")
    print(f"static let keepFrom = {threshold:.2f}")
    for name, value in zip(FEATURES, w[1:]):
        print(f"//   {name:<16} {value:+.3f}")


if __name__ == "__main__":
    main()
