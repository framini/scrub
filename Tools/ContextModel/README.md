# Context model

A pretrained multilingual encoder (Multilingual-MiniLM-L12-H384: 12 layers,
384 wide), fine-tuned to tag personal details from the sentence around them:
places, employers tied to a person, names in non-Latin scripts, handles, and
IDs, secrets and birth dates no label announces. Scrub runs it on-device
through Accelerate (`Sources/ScrubCore/ContextModel.swift`,
`PieceTokenizer.swift`, `ContextStage.swift`). Its base model, training data
and licences are in `THIRD_PARTY_NOTICES.md`.

Nothing in this folder ships in Scrub or runs at build time. Scrub ships only
the weight file, as ordinary git files `Sources/ScrubCore/Resources/ContextModel.1.bin`
and `.2.bin` (each under 45 MB). `ContextModel.swift` joins them and checks the
SHA-256 held in `ContextWeights.shipped`; a part missing or changed leaves
Scrub without the model, never with a damaged one.

The same scripts also train a base-size encoder (XLM-RoBERTa base, 12 layers,
768 wide, `train.py --base base`) and export it (`export.py --name
ContextModelBase`, six parts, about 245 MB). It was measured against the small
model on the same text and did not catch more on real text, at three times the
size and run time, so Scrub does not load it; the Swift network reads its
dimensions from the file and runs either width.

## Files

- `fetch_data.py` downloads the real labelled training text at pinned
  revisions and checks each file's SHA-256: WNUT-17's training split (CC BY
  4.0) and the Text Anonymization Benchmark's training split (MIT); with
  `--share-alike`, also Few-NERD (CC BY-SA 4.0) and WikiANN (Wikipedia, CC
  BY-SA) for comparison builds. The Broad Twitter Corpus and WNUT-17's test
  and development splits are never fetched: Scrub's real-text evaluation uses
  them, as it uses TAB's development and test splits.
- `real_data.py` turns that text into training documents (label mapping
  below), holds out the names, towns and companies the benchmarks use, and
  drops anything matching the real-text evaluation sets (`dedupe.py`).
- `dedupe.py` drops training text that matches an evaluation text: exact,
  after normalising, sentence by sentence, or by a shared run of 10 words.
  Evaluation text is only hashed in memory; none of it is written.
- `generate_context.py` writes labelled generated text. It builds on
  `../NameModel/generate.py`, and holds out the towns, companies, non-Latin
  names and ID labels the benchmarks use.
- `prune.py` cuts the base tokenizer's 250k pieces to those the scripts in
  scope and the training text need (81k for the shipped model), and records
  which embedding rows to keep.
- `train.py` fine-tunes either base encoder (`--base small|base`).
- `export.py` writes the weight file: the tokenizer (pieces, scores, the
  normaliser's trie), the gate's word lists (`common-words.txt` and the
  system's `/usr/share/dict/words`), int8 piece embeddings with one scale a
  row, an fp16 body, and float32 biases, norms and classifier. For a RoBERTa
  body it drops the two padding positions from the position table, so every
  build reads positions from 0. It prints the SHA-256 to put in `ContextWeights`.
- `parity.py` writes the fixtures that check the Swift tokenizer and network
  against Python: `Tests/ScrubCoreTests/Fixtures/context-{tokenizer,model}-parity.json`.

## Label mapping

| Source | PERSON | LOCATION | ID | DOB | ORG (employer) | USERNAME | no label |
|---|---|---|---|---|---|---|---|
| WNUT-17 | person | location | — | — | corporation, group, only when the sentence speaks of someone's work | every @mention | product, creative-work |
| TAB | PERSON (any identifier type) | LOC marked DIRECT or QUASI | CODE marked DIRECT or QUASI | DATETIME right after "born", "born on", "born in" | ORG, as above | — | LOC and CODE marked NO_MASK, other DATETIME, DEM, MISC, QUANTITY |
| Few-NERD (comparison only) | person-* | location-* | — | — | organization-*, building-*, as above | — | art, event, product, other |
| WikiANN (comparison only) | PER | LOC | — | — | ORG, as above | — | — |

- "Speaks of someone's work" is ContextStage's employer rule (`works at`,
  `manager`, `hired`, …) without its loosest cue (`as a …`). A hashtag is never labelled.
- TAB is read with the first annotator (by name) of each judgment, the way
  Scrub's evaluation reads its other splits, and cut into paragraphs.
  Judgments share boilerplate, so the evaluation check drops paragraphs, not
  whole judgments: 6,540 of them matched evaluation text.
- A document is held out when a labelled value has a name the benchmarks use
  (titles, initials and common words do not count).
- The person class is used for every script. A person in Latin script counts
  only where something independent of the model agrees, weighed by the person
  scorer (`../PersonScorer`).
- The generated text also has numbers of applications, claims and files cited
  as "no. 12345/06" (labelled ID), against numbers of laws, articles and
  regulations ("Article 6 § 1", "Regulation (EU) 2016/679", unlabelled).
- With `--share-alike`, `real_data.py` also swaps a WikiANN name in another
  script into some English sentences, and as many ordinary words in another
  script, unlabelled, so a script alone does not make a name.

## Rebuilding

```sh
uv venv -p 3.12.11 .venv && VIRTUAL_ENV=.venv uv pip install -r requirements.txt
D=~/Work/scrub-train-data   # outside the repository
E=~/Work/scrub-eval-data    # the real-text evaluation sets, never trained on
.venv/bin/python fetch_data.py $D/raw
.venv/bin/python real_data.py $D/raw $D/realw-train.jsonl $D/realw-valid.jsonl --eval $E          # WNUT-17
.venv/bin/python real_data.py $D/raw $D/realt-train.jsonl $D/realt-valid.jsonl --tab --eval $E    # WNUT-17 and TAB
(cd ../NameModel && ../ContextModel/.venv/bin/python extract_prose.py) > $D/prose.txt
.venv/bin/python dedupe.py $E $D/prose.txt $D/prose-clean.txt
.venv/bin/python generate_context.py --count 80000 --seed 11 --prose $D/prose-clean.txt > $D/gen-train.jsonl
.venv/bin/python generate_context.py --count 4000 --seed 12 --prose $D/prose-clean.txt > $D/gen-valid.jsonl
.venv/bin/python dedupe.py $E $D/gen-train.jsonl $D/gen-train-checked.jsonl   # drops 2 legal citations
.venv/bin/python prune.py $D/pruned --min-count=3 $D/gen-train-checked.jsonl $D/realt-train.jsonl $D/prose-clean.txt /usr/share/dict/words
# Generated text, TAB once and WNUT-17 three times:
.venv/bin/python train.py --base small --tokenizer $D/pruned \
    --train $D/gen-train-checked.jsonl $D/realt-train.jsonl $D/realw-train.jsonl $D/realw-train.jsonl \
    --valid $D/gen-valid.jsonl $D/realt-valid.jsonl --out $D/small
.venv/bin/python export.py --model $D/small --out ../../Sources/ScrubCore/Resources
.venv/bin/python parity.py --model $D/small --valid $D/gen-valid.jsonl --prose $D/prose-clean.txt \
    --tokens ../../Tests/ScrubCoreTests/Fixtures/context-tokenizer-parity.json \
    --logits ../../Tests/ScrubCoreTests/Fixtures/context-model-parity.json
```

Training takes about 40 minutes on an M1 Max GPU (the base build, `--base
base --lr 3e-5`, about 90). Then set the printed checksum in
`ContextWeights.shipped`, and run the whole test suite (PIIGaps, NameGaps,
the parity tests) and the payload properties on several seeds. To try the
base build in Scrub, export it with `--name ContextModelBase`, add its parts
to `Package.swift` and give `ContextWeights.shipped` its name, six parts and checksum.

The shipped model was built from these inputs (SHA-256):

| Input | SHA-256 |
|---|---|
| prose.txt (48,488 lines; the first model's) | `135dea0418266d95a2b93151811270a20bbf8fc65de640b4b6e3d11dadb36031` |
| prose-clean.txt (47,888 lines) | `381018f802007face202a4b7f8940047dd7f5b94daf0509e209a817009ba7353` |
| gen-train-checked.jsonl (79,998 documents) | `7783b8d9e46118f700036dae81dabfb2bbffa217da2f6916735d71d0fb59af76` |
| gen-valid.jsonl | `1c8bf66b0ccb44e3724874c40e9f98b9101d3b5dc65bae45ecb37843e1c091b6` |
| realw-train.jsonl (3,284 WNUT-17 sentences) | `55c926034ac51e827ecac966a6d809006f759235d2e7a94945f42d508475c8ff` |
| realt-train.jsonl (3,284 WNUT-17 sentences, 17,995 TAB paragraphs) | `4cea814576e1e58b8b5c5cdc60d08b1c8b8577bd881efb32ae296334f38d77a2` |
| realt-valid.jsonl | `27dd11acdd38ea76670f03ec892ac8031775061c27db52242a91ba334aaf1170` |
| pruned/tokenizer.json (81,302 pieces) | `e0eed6d68ead8d90e93daa81abcfdc2f2c1bd731e8d51efc63ad8f7711601690` |
| /usr/share/dict/words (macOS 26) | `be41ad97963bf8dabedd5871d5d691596175269d540956b0f9965a885c2bbab9` |
| checkpoint model.safetensors | `2a262d3dc6faeeea3a622215f7893e49bbfefca54f135387f1dd54a2597a4c9a` |
| ContextModel.1.bin + .2.bin, joined | `7a403a6536d0205b9eccad7dded5216fb04dfe7a403bff5ab445a10fd1f9dd28` |

What is reproducible, and what is not:

- From the same checkpoint, `export.py` writes the same bytes every time.
- `fetch_data.py` checks every download against its pinned SHA-256;
  `real_data.py`, `dedupe.py`, `generate_context.py` and `prune.py` are exact
  given the same inputs.
- The prose comes from this Mac's man pages, filtered by the names Scrub knows
  (`extract_prose.py`), so it changes with macOS and with `Names.swift`.
- The evaluation sets decide what `dedupe.py` drops, so a change to them can
  change the training text.
- GPU training is not bit-for-bit repeatable. A retrain gives a comparable
  model, not the same file; check it against the benchmarks before shipping.
