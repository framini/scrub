# Address model

A small network (1.7M parameters, 2 MB) that marks postal addresses in
text, each as one unit: its unit and building lines, street, locality,
postcode and country. Scrub runs it on-device through Accelerate, beside the
street pattern and the system's data detector, to catch what they miss: an
address in another country's format, a flat or a box over its town, a
signature's address on one line, a street in a sentence with no postcode.

It reads only the lines around one that holds a digit and a word, so text
with no numbers costs nothing. Its findings take in the address parts other
detectors found inside them and are replaced as one address. They never
cross a link, a label, a greeting, a field of pasted JSON or YAML, or a
number filed under an order or a case; they give way to anything surely
something else (an email, a phone number, a name a rule found); and they
need something only an address holds (a kind of street, a unit or box, a
postcode beside a place or of a telling shape, a known region, country or
city). An address only the model found scores 0.6, so it is shown for review
before sharing. The correction sweep, which reads text that already holds
stand-ins, leaves it out, as it does the name model.

## Files

- `fetch_data.py` downloads the address parts into `raw/`.
- `places.py` loads them: localities and postcodes per country, US street
  names, and hand-written street words per language. One value in ten (by a
  stable hash) is held out for the test set only.
- `addresses.py` writes addresses in 27 countries' own formats.
- `generate.py` sets them in signatures, letters, prose, forms, chat and
  pasted JSON, CSV, XML, YAML and logs, beside hard negatives: versions,
  order and ticket numbers, times, quantities, seats, code, tables, dated
  sentences, product titles, social posts and man pages. A document sharing
  eight words in a row with the evaluation corpus is dropped.
- `tiger_streets.py` extracts the US street names; `extract_man.py` collects
  this Mac's man page paragraphs, without authors' postal addresses.
- `model.py` holds the tokenizer, features and network.
  `Sources/ScrubCore/AddressModel.swift` mirrors it; change both together.
- `train.py` trains, scores the held-out set and writes the weights.
- `evaluate.py` scores a file of handwritten cases, addresses marked ⟦…⟧,
  invented throughout:
  - `handwritten.txt` was written first and used to compare training runs;
  - `handwritten-final.txt` was scored on one run, which then shaped the
    look-alikes the generator writes, so it is no longer a clean test;
  - `handwritten-holdout.txt` was written before the shipped weights were
    chosen and scored once, after.
- `corpus_check.py` measures a checkpoint on the evaluation corpus during
  development. It never feeds training.
- `parity.py` writes the fixture that checks the Swift port gives the same
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
for i in 0 1 2 3; do .venv/bin/python generate.py --count 100000 --seed $((17+i*1000)) > data/train.$i.jsonl; done
cat data/train.?.jsonl > data/train.jsonl
.venv/bin/python generate.py --count 5000 --seed 199 > data/valid.jsonl
.venv/bin/python generate.py --count 5000 --seed 223 --holdout > data/test.jsonl
.venv/bin/python train.py --train data/train.jsonl --valid data/valid.jsonl --test data/test.jsonl --epochs 3 --out ../../Sources/ScrubCore/Resources/AddressModel.bin
.venv/bin/python evaluate.py --load ../../Sources/ScrubCore/Resources/AddressModel.bin.pt --cases handwritten.txt
.venv/bin/python parity.py --load ../../Sources/ScrubCore/Resources/AddressModel.bin.pt > ../../Tests/ScrubCoreTests/Fixtures/address-model-parity.json
rm ../../Sources/ScrubCore/Resources/AddressModel.bin.pt
```

`ADDRESS_GEONAMES`, `ADDRESS_US_STREETS`, `ADDRESS_MAN` and
`ADDRESS_NAME_LISTS` point the generator at data kept elsewhere. Training
takes about 20 minutes on an M1 Max and is not bit-for-bit repeatable,
so a retrained file differs from the shipped one. Write its SHA-256 into
`AddressModel.checksum`, then run the whole test suite, PIIGaps included,
and the payload properties on several seeds.

The shipped weights: 400,000 generated documents (280,602 addresses in 237,810 of them), 3 epochs. On 5,000
held-out generated documents (held-out localities, streets and names) the
model marks 98.0% of addresses exactly and no address in any of the 2,036
documents without one. On `handwritten-holdout.txt` it marks 88% exactly
(92% in full or within a wider span) and nothing in its 15 look-alikes.
