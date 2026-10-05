# Name model

A small network (1.6M parameters, 2 MB) that reads each word with the words
around it and says whether it names a person. Scrub runs it on-device through
Accelerate, next to the system name tagger, to catch names the tagger cannot
read: a first name alone after "Thanks,", a greeting, a lowercase name in
chat, a handle built from a name.

It only fills gaps. Its findings score below every other detector's, are
dropped wherever another detector or the system tagger's organisation names
found something, and are left out of the correction sweep, which reads text
that already holds stand-ins.

## Files

- `generate.py` writes labelled training text. Names are partly invented from
  the name lists, so the model learns names from their spelling and context
  rather than by heart. Everything the NameGaps benchmark uses is left out.
- `extract_prose.py` collects plain English sentences with no people in them
  from this Mac's man pages, so ordinary words are not names by default.
- `model.py` holds the tokenizer, features and network.
  `Sources/ScrubCore/NameModel.swift` mirrors it; change both together.
- `train.py` trains, scores a NameGaps dump and writes the weights.
- `parity.py` writes the fixture that checks the Swift port gives the same
  scores as PyTorch.

## Retraining

Python 3.12 with PyTorch, at the versions in `requirements.txt`:

```sh
uv venv -p 3.12.11 .venv && VIRTUAL_ENV=.venv uv pip install -r requirements.txt
python3 extract_prose.py > prose.txt
python3 generate.py --count 250000 --seed 7 --prose prose.txt > train.jsonl
python3 generate.py --count 5000 --seed 99 --prose prose.txt > valid.jsonl
(cd ../.. && SCRUB_GAPS_SEED=2 SCRUB_GAPS_CASES=200 SCRUB_GAPS_DUMP=$PWD/Tools/NameModel/gaps.jsonl swift test --filter NameGaps)
.venv/bin/python train.py --train train.jsonl --valid valid.jsonl --gaps gaps.jsonl --out ../../Sources/ScrubCore/Resources/NameModel.bin
.venv/bin/python parity.py --load ../../Sources/ScrubCore/Resources/NameModel.bin.pt > ../../Tests/ScrubCoreTests/Fixtures/name-model-parity.json
rm ../../Sources/ScrubCore/Resources/NameModel.bin.pt
```

Training takes about three minutes on Apple silicon. Then run the whole test
suite, NameGaps included, and the payload properties on several seeds.
