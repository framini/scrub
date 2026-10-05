# Address model

Two small networks (1.7M parameters, 2 MB each) that mark postal addresses
in text, each as one unit: its unit and building lines, street, locality,
postcode and country. Scrub runs both on-device through Accelerate, beside
the street pattern and the system's data detector, to catch what they miss:
an address in another country's format, a flat or a box over its town, a
signature's address on one line, a street in a sentence with no postcode.

- The first model (`AddressModel.bin`) reads only the lines around one that
  holds a digit and a word.
- The wide model (`AddressModelWide.bin`) also reads lines with no number
  that hold something only an address line has (`prefilter.py`): a word
  ending in a compound kind of street ("Hauptstraße", "Strandvejen"), a
  foreign kind of street opening a name ("rue des Lilas"), a capitalised kind
  of street or building after a capitalised word ("Mill Lane", "The Old
  Rectory"), or a unit with a letter ("Flat B"). It passes about one prose
  line in a thousand that the first would not read. It was trained with
  addresses written all in lowercase, with no number, and in more languages,
  and it reads one more feature: whether a token's line holds a capital
  letter.

Scrub keeps what either model finds, joining findings that overlap: the
first model's findings stay as they were, and the wide one adds what it
misses. Text with no digit and no such cue costs only a scan of its words.

An address with no number needs a kind of street, a building or a unit in
one piece and another piece beside it ("Flat B, The Old Rectory, Little
Hadham", "Hauptstraße, Berlin-Mitte"). An address written all in lowercase
needs a postcode, a unit or box with its number, or a place Scrub knows
("14 rookery lane, leeds ls6 2ab"), so "take bus 14 to market street"
stays; its stand-in is written in lowercase too.

The findings take in the address parts other detectors found inside them and
are replaced as one address. They never cross a link, a label, a greeting, a
field of pasted JSON or YAML, or a number filed under an order or a case;
they give way to anything surely something else (an email, a phone number, a
name a rule found); and they need something only an address holds (a kind of
street, a unit or box, a postcode beside a place or of a telling shape, a
known region, country or city). An address only a model found scores 0.6, so
it is shown for review before sharing. The correction sweep, which reads text
that already holds stand-ins, leaves them out, as it does the name model.

## Files

- `fetch_data.py` downloads the address parts into `raw/`.
- `places.py` loads them: localities and postcodes per country, US street
  names, hand-written street words per language, house names and counties.
  One value in ten (by a stable hash) is held out for the test set only.
  Germany's file also names firms and offices with a postcode of their own
  ("… Versicherung AG", "Stadtverwaltung"); the wide model's data leaves
  them out, the first model's kept them.
- `addresses.py` writes addresses in 27 countries' own formats, and with
  no number at all in 20 of them ("The Granary, Manor Farm, Long Compton",
  "Hauptstraße, Berlin-Mitte", "rue des Lilas, Nantes").
- `generate.py` sets them in signatures, letters, prose, forms, chat and
  pasted JSON, CSV, XML, YAML and logs, beside hard negatives: versions,
  order and ticket numbers, times, quantities, seats, code, tables, dated
  sentences, product titles, social posts and man pages. With `--no-extra`
  it writes the first model's data, byte for byte. Without it, it adds
  lead-ins and tails in eleven languages and look-alikes that name streets,
  buildings and places: directions, board games, titles, legal citations in
  several languages, manual references, firms named after streets, and news
  ("Downing Street said …"). `--lowercase` writes that share of documents
  all in lowercase (and half as many addresses typed in lowercase in cased
  text), `--numberless` that share of addresses with no number, and `--v6`
  adds replies quoted with "> ", buildings named by a number in words ("Four
  Kessler Plaza") and more country lines. A document sharing eight words in
  a row with the evaluation corpus is dropped.
- `tiger_streets.py` extracts the US street names; `extract_man.py` collects
  this Mac's man page paragraphs, without authors' postal addresses.
- `model.py` holds the tokenizer, features and network. `ADDRESS_WIDE=1`
  selects the wide model's features (one more line flag) for every script.
  `Sources/ScrubCore/AddressModel.swift` mirrors it; change both together.
- `prefilter.py` is the line prefilter, mirrored from `AddressModel.swift`.
- `train.py` trains, scores the held-out set and writes the weights.
- `evaluate.py` scores one model's raw spans on a file of handwritten
  cases, addresses marked ⟦…⟧, invented throughout. `bench.py` scores them
  as Scrub reads text: the prefilter's windows, the model's spans, the
  acceptance rules, and (with `BENCH_UNION`) both models joined. Its "words"
  column counts an address as found when every distinctive word of it is
  inside a finding, however the findings split it.
  - `handwritten.txt` was written first and used to compare the first
    model's training runs;
  - `handwritten-final.txt` was scored on one run, which then shaped the
    look-alikes the generator writes, so it is no longer a clean test;
  - `handwritten-holdout.txt` was written before the first model's weights
    were chosen and scored once, after;
  - `handwritten-lowercase.txt`, `handwritten-numberless.txt`,
    `handwritten-multilingual.txt` and `handwritten-business.txt` (US
    business mail: quoted replies, building names, mail codes, capitals)
    were written before the wide model's first run and used to compare its
    runs;
  - `handwritten-holdout2.txt` was written with them, never looked at by a
    run, and scored once, on the shipped pair.
- `corpus_check.py` measures a model, or the pair (`--dump` then
  `--union`), on the evaluation corpus as a final check. It never feeds
  training or tuning.
- `parity.py` writes the fixtures that check the Swift port gives the same
  scores and addresses as PyTorch.

## Data and licences

- **Localities and postcodes:** GeoNames postal code files
  (https://download.geonames.org/export/zip/), CC BY 4.0. The UK, Canadian
  and Irish files hold only the first part of each postcode; the rest is
  drawn at random.
- **US street names:** US Census Bureau TIGER/Line 2024 FEATNAMES, for the
  counties in `tiger-counties.txt`. A work of the U.S. Government, in the
  public domain.
- **Names:** Scrub's own name lists (`Sources/ScrubCore/Resources/NameLists.txt`,
  public domain sources; see THIRD_PARTY_NOTICES.md).
- **Man pages:** this Mac's, read locally for negatives and never shipped.

Street words, building words, templates and every number are written here.
No OpenStreetMap-derived or share-alike data is used.

## Retraining

Python 3.12 with PyTorch, at the versions in `requirements.txt`. The
evaluation corpus must be at `SCRUB_EVAL_DATA` (default
`~/Work/scrub-eval-data`) so the generator can keep its text apart from it.

```sh
uv venv -p 3.12.11 .venv && VIRTUAL_ENV=.venv uv pip install -r requirements.txt
mkdir -p data
.venv/bin/python fetch_data.py
.venv/bin/python tiger_streets.py
.venv/bin/python extract_man.py > data/man.txt
R=../../Sources/ScrubCore/Resources F=../../Tests/ScrubCoreTests/Fixtures

# The first model: AddressModel.bin
for i in 0 1 2 3; do .venv/bin/python generate.py --no-extra --count 100000 --seed $((17+i*1000)) > data/train.$i.jsonl; done
cat data/train.?.jsonl > data/train.jsonl
.venv/bin/python generate.py --no-extra --count 5000 --seed 199 > data/valid.jsonl
.venv/bin/python generate.py --no-extra --count 5000 --seed 223 --holdout > data/test.jsonl
.venv/bin/python train.py --train data/train.jsonl --valid data/valid.jsonl --test data/test.jsonl --epochs 3 --out $R/AddressModel.bin
.venv/bin/python parity.py --load $R/AddressModel.bin.pt > $F/address-model-parity.json

# The wide model: AddressModelWide.bin
W="--lowercase 0.05 --numberless 0.06 --v6"
for i in 0 1 2 3; do .venv/bin/python generate.py $W --count 100000 --seed $((17+i*1000)) > data/wide.$i.jsonl; done
cat data/wide.?.jsonl > data/wide.jsonl
.venv/bin/python generate.py $W --count 5000 --seed 199 > data/wide-valid.jsonl
.venv/bin/python generate.py $W --count 5000 --seed 223 --holdout > data/wide-test.jsonl
ADDRESS_WIDE=1 .venv/bin/python train.py --train data/wide.jsonl --valid data/wide-valid.jsonl --test data/wide-test.jsonl --epochs 3 --seed 2 --out $R/AddressModelWide.bin
ADDRESS_WIDE=1 .venv/bin/python parity.py --load $R/AddressModelWide.bin.pt > $F/address-model-wide-parity.json

# Compare runs as Scrub reads text: the first model alone, then joined with the wide one.
BENCH_DUMP=data/first.jsonl .venv/bin/python bench.py --load $R/AddressModel.bin.pt --first
BENCH_UNION=data/first.jsonl ADDRESS_WIDE=1 .venv/bin/python bench.py --load $R/AddressModelWide.bin.pt
rm $R/*.bin.pt
```

`ADDRESS_GEONAMES`, `ADDRESS_US_STREETS`, `ADDRESS_MAN` and
`ADDRESS_NAME_LISTS` point the generator at data kept elsewhere. Each
training run takes about 20 minutes on an M1 Max (longer on a busy machine)
and is not bit-for-bit repeatable, so a retrained file differs from the
shipped one: two runs of one recipe differ by one or two addresses in each
handwritten set. Write each file's SHA-256 into `AddressModel.Weights`, then
run the whole test suite, PIIGaps included, and the payload properties on
several seeds.

## The shipped weights

**The first model:** 400,000 generated documents (280,602 addresses in
237,810 of them), 3 epochs. On 5,000 held-out generated documents
(held-out localities, streets and names) it marks 98.0% of addresses
exactly and no address in any of the 2,036 documents without one. On
`handwritten-holdout.txt` it marks 88% exactly (92% in full or within a
wider span) and nothing in its 15 look-alikes.

**The wide model:** 400,000 generated documents (279,367 addresses in
237,088 of them; 13,039 with no number and 20,647 all in lowercase), 3
epochs, seed 2, chosen over a seed-1 run of the same recipe by the
development sets. On 5,000 held-out generated documents of its own recipe it
marks 97.6% of addresses exactly and no address in any of the 2,040
documents without one.

**The pair, as Scrub reads text** (`bench.py`, "words": every distinctive
word inside a finding), first model alone → both:

| Set | Addresses | First model | Both | Look-alikes with a finding |
|---|---|---|---|---|
| `handwritten.txt` | 57 | 54 | 55 | 0/37 → 0/37 |
| `handwritten-final.txt` | 31 | 27 | 29 | 0/20 → 0/20 |
| `handwritten-holdout.txt` | 25 | 24 | 25 | 0/15 → 1/15 (a time, "10:15 in Room 2.07", which Scrub's rule drops) |
| `handwritten-business.txt` | 17 | 14 | 16 | 1/8 → 1/8 |
| `handwritten-lowercase.txt` | 22 | 9 | 20 | 0/15 → 0/15 |
| `handwritten-numberless.txt` | 17 | 0 | 16 | 0/15 → 0/15 |
| `handwritten-multilingual.txt` | 22 | 22 | 22 | 1/13 → 1/13 |
| 600 held-out generated documents | 422 | 404 | 406 | 0/236 → 0/236 |
| `handwritten-holdout2.txt` (scored once) | 22 | 8 | 18 | 1/15 → 1/15 |

Training the first model's recipe with 3% of documents in lowercase lost
addresses in this table's cased sets only by its "covered" count (one
finding holding the whole address): it split more multi-line addresses at
a line start, and the words count, which Scrub's replacement follows, did
not move beyond the one or two addresses two runs of one recipe differ by.
Lowering the threshold to 0.3 or 0.4 brought back one address at most.
The capital-letter line flag helped the lowercase and numberless sets more
than the cased ones; running both models is what keeps the cased sets at
least where the first model alone had them.
