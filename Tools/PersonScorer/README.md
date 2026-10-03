# Person scorer

Two of Scrub's models guess people that the system tagger and the rules
miss: the name model reads the letters of a word and its neighbours, and the
context model reads the whole sentence. Each is wrong in its own way, so a
guess counts only when something else agrees. `Sources/ScrubCore/PersonScorer.swift`
holds the signals Scrub knows about each guess and a logistic regression
that weighs them. Its output decides whether the guess is kept, and is the
confidence the finding carries into review.

This folder holds the script that fits the regression's 25 weights and its
bias. Nothing here ships in Scrub or runs at build time: the weights are
written into the Swift source. `fit.py` uses the Python standard library
only, so there is nothing to install. The shipped weights were fitted with
Python 3.14.6; the fit is deterministic, so the same rows give the same weights.

## The signals

| Signal | What it says |
|---|---|
| `nameModel`, `nameModelFound` | The name model's surest score for a word of the guess, as a logit, and whether that clears its own threshold |
| `context`, `contextFound` | How far the context model leaned to a person over it, as log-odds, and whether it read one there at all |
| `first`, `surname` | A word of it is a listed first name or surname that is no ordinary word |
| `wordlike`, `ordinary`, `unknownCapital` | A name that is also a word ("June"); only ordinary words ("Later"); a capitalised word no list or dictionary has |
| `title`, `greeting`, `strong`, `position`, `subject` | A title or rank before it; a greeting or sign-off; a strong cue (`NameCues.strong`); written as a name (`NameCues.position`); a lowercase word after it, as after a subject |
| `capitalised`, `lowercase`, `allCaps`, `oneWord`, `threeWords`, `opens` | How it is written, how long it is, and whether it opens a line or sentence |
| `organisation`, `place`, `determiner`, `version`, `placeCue` | Part of an organisation's name; a town or region; an article or determiner before it ("the Jenkins build"); a version number after it ("Darwin 25.6.0"); words before it that lead to a place ("lives in", "moved to") |

A context-model guess in Latin script is considered at all only when
something independent of the context model agrees (`PersonScorer.agrees`):
the name model calls it a name, a word is a listed first name or surname
that is no ordinary word, a title, a greeting or sign-off, or a cue. A single
word opening a sentence before a lowercase word ("Siri misheard", "Corvane
was founded") needs the name model, since the lists and the cue say nothing
there that a person's name would not, and a lowercase word alone needs a
list, the name model, a title or a greeting. An organisation, a town, a word
after an article, before a version number or where a place goes, and a piece
of a handle or an address ("priya" of "priya.r") never count. Neither
model's guess is kept when it is made of ordinary words with nothing around
it that marks a name (`NameShape.ordinaryGuess`). These are the hand rules;
the scorer decides among the guesses they let through.

## Data

Only generated text and permissive training text, never the real-text
evaluation sets (`~/Work/scrub-eval-data`).

| Set | Source | Use |
|---|---|---|
| `gen-41` | `../ContextModel/generate_context.py --count 8000 --seed 41 --prose prose-clean.txt` (a seed the context model was not trained on) | fitting (70% of documents) and held out (30%) |
| `gen-valid-final` | the context model's own held-out generated set (seed 12, `../ContextModel/README.md`) | fitting and held out, as above |
| `gaps-9001`, `gaps-9002` | `PersonScorerData.generatedCases` with `SCRUB_PERSON_GAPS_SEED=9001` and `9002`, 80 cases a category: NameGaps cases, and the PIIGaps categories whose people are all labelled, with the towns and companies beside people labelled as no one (the benchmarks' own seed, 1, is refused) | fitting and held out, as above |
| `realt-valid` | the context model's held-out real set: WNUT-17 (CC BY 4.0) and TAB (MIT) validation documents, never trained on (`../ContextModel/real_data.py`) | held out only: never fitted on |

## Recipe

```sh
D=/some/scratch/dir
python3 ../ContextModel/generate_context.py --count 8000 --seed 41 --prose $DATA/prose-clean.txt > $D/gen-41.jsonl
cp $DATA/gen-valid-final.jsonl $DATA/realt-valid.jsonl $D/
for seed in 9001 9002; do
  SCRUB_PERSON_GAPS_OUT=$D/gaps-$seed.jsonl SCRUB_PERSON_GAPS_SEED=$seed SCRUB_PERSON_GAPS_CASES=80 \
    swift test --filter PersonScorerData/generatedCases
done
for f in gen-41 gen-valid-final realt-valid gaps-9001 gaps-9002; do
  SCRUB_PERSON_SIGNALS=$D/$f.jsonl SCRUB_PERSON_SIGNALS_OUT=$D/sig-$f.tsv swift test --filter PersonScorerData/signals
done
python3 fit.py $D/sig-gen-41.tsv $D/sig-gen-valid-final.tsv $D/sig-realt-valid.tsv $D/sig-gaps-9001.tsv $D/sig-gaps-9002.tsv
```

`$DATA` is the context model's data folder (`../ContextModel/README.md`).
`PersonScorerData.signals` runs the detector with the context model on each
document and writes one row per guess (its signals, what the hand rules
decide, and whether it overlaps a labelled person or handle) and one per
labelled person (whether another detector already found it).

`fit.py`:
1. splits generated documents 70/30 by a hash of their id, and holds out all real text;
2. fits the regression on the distinct guesses the hand rules let through in
   the fitting part, by Newton's method with an L2 penalty of 1;
3. picks the threshold: on the fitting part, every person the hand rules
   catch, then the fewest words changed outside a labelled span;
4. compares the scorer with the hand rules on the held-out part, by set,
   counting people caught (by any detector) and words changed outside any label;
5. prints the calibration of its probability on held-out real and generated
   text, and the weights as Swift.

Paste the printed `bias`, `weights` and `keepFrom` into `PersonScorer`. A
test checks that the weights and the signals agree in number.

## The shipped weights

On the held-out part, against the hand rules (people caught / words changed
outside a label):

| Set | Hand rules | Scorer |
|---|---|---|
| generated (`gen`) | 3,397 / 45 | 3,397 / 44 |
| NameGaps cases | 677 / 34 | 674 / 24 |
| PIIGaps cases | 254 / 35 | 254 / 9 |
| TAB, real court text | 154 / 10 | 153 / 5 |
| WNUT-17, real tweets | 36 / 11 | 36 / 11 |

It keeps a guess from probability 0.08. On held-out real text, kept guesses
at 0.7 and above are people 96% of the time (79 of 82). A kept guess's confidence is
its probability, between 0.5 and 0.85, so those below 0.65 are asked about
before sharing (`Finding.reviewBelow`).

Some weights are negative for signals that mark a name (`nameModelFound`,
`strong`). They overlap with others (the name model's score, `greeting`,
`title`), and the regression splits their weight between them. Read the
signals together, not one weight at a time.

## Limits

- The generated text is easy: almost every guess there is a person, and the
  context model is surer of it than of real text. The real sets are small
  (177 and 88 labelled people), so the held-out comparison on real text
  rests on a few dozen guesses.
- The scorer judges only guesses where the context model read the whole
  text. Elsewhere, as for a value of one or two words, the name model's
  guesses keep the hand rule they always had.
