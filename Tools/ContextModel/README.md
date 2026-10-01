# Context model

A pretrained multilingual encoder (12 layers, 384 wide, 54M parameters),
fine-tuned to tag personal details from the sentence around them: places,
employers tied to a person, names in non-Latin scripts, handles, and IDs,
secrets and birth dates no label announces. Scrub runs it on-device through
Accelerate (`Sources/ScrubCore/ContextModel.swift`, `PieceTokenizer.swift`,
`ContextStage.swift`). Its base model and licence are in
`THIRD_PARTY_NOTICES.md`.

Nothing in this folder ships in Scrub or runs at build time. Scrub ships only
the weight file, as ordinary git files `Sources/ScrubCore/Resources/ContextModel.1.bin`
and `.2.bin` (each under 45 MB). `ContextModel.swift` joins them and checks the
SHA-256 it holds in code; a part missing or changed leaves Scrub without the
model, never with a damaged one.

## Files

- `generate_context.py` writes labelled training text. It builds on
  `../NameModel/generate.py`, and holds out the towns, companies, non-Latin
  names and ID labels the benchmarks use.
- `prune.py` cuts the base tokenizer's 250k pieces to the 84k the scripts in
  scope and the training text need, and records which embedding rows to keep.
- `train.py` fine-tunes the base encoder on the generated text.
- `export.py` writes the weight file: the tokenizer (pieces, scores, the
  normaliser's trie), the gate's word lists (`common-words.txt` and the
  system's `/usr/share/dict/words`), int8 piece embeddings with one scale a
  row, an fp16 body, and float32 biases, norms and classifier. It prints the
  SHA-256 to put in `ContextModel.checksum`.
- `parity.py` writes the fixtures that check the Swift tokenizer and network
  against Python: `Tests/ScrubCoreTests/Fixtures/context-*-parity.json`.

## Rebuilding

```sh
uv venv -p 3.12.11 .venv && VIRTUAL_ENV=.venv uv pip install -r requirements.txt
(cd ../NameModel && ../ContextModel/.venv/bin/python extract_prose.py) > prose.txt
.venv/bin/python generate_context.py --count 80000 --seed 11 --prose prose.txt > train.jsonl
.venv/bin/python generate_context.py --count 4000 --seed 12 --prose prose.txt > valid.jsonl
.venv/bin/python prune.py pruned train.jsonl prose.txt /usr/share/dict/words
.venv/bin/python train.py --tokenizer pruned --train train.jsonl --valid valid.jsonl --out checkpoint
.venv/bin/python export.py --model checkpoint --out ../../Sources/ScrubCore/Resources
.venv/bin/python parity.py --model checkpoint --valid valid.jsonl --prose prose.txt \
    --tokens ../../Tests/ScrubCoreTests/Fixtures/context-tokenizer-parity.json \
    --logits ../../Tests/ScrubCoreTests/Fixtures/context-model-parity.json
```

Training takes about 50 minutes on an M1 Max GPU. Then set the printed
checksum in `ContextModel.swift`, and run the whole test suite (PIIGaps,
NameGaps, the parity tests) and the payload properties on several seeds.

What is reproducible, and what is not:

- From the same checkpoint, `export.py` writes the same bytes every time.
- From the same training text, `generate_context.py` and `prune.py` are exact:
  seeds 11 and 12 and the shipped run's prose give byte-identical files.
- The prose comes from this Mac's man pages, filtered by the names Scrub knows
  (`extract_prose.py`), so it changes with macOS and with `Names.swift`.
- GPU training is not bit-for-bit repeatable. A retrain gives a comparable
  model, not the same file; check it against the benchmarks before shipping.

The shipped file was built from these inputs (SHA-256):

| Input | SHA-256 |
|---|---|
| prose.txt (48,488 lines) | `135dea0418266d95a2b93151811270a20bbf8fc65de640b4b6e3d11dadb36031` |
| train.jsonl | `8ae172452a5cc0636bc776a813586702ee0a81af2b6bfa2f327e94cc706b56c9` |
| valid.jsonl | `9b6ede90ba34c9baf6b262a9e4d70503ca56575c3d4e5b72dfdb03ef8e11538c` |
| pruned/tokenizer.json | `62129ae7370428a4b820443ab90280f0b88e7b3ce2888dc081857a201935fb33` |
| /usr/share/dict/words (macOS 26) | `be41ad97963bf8dabedd5871d5d691596175269d540956b0f9965a885c2bbab9` |
| checkpoint/model.safetensors | `37d6f2cd753bb7f041b2d93d19b06a204e83bd10aed7c746ded2ceac6f01ebb5` |
| the weight file, both parts joined | `7206a189c4d511dcd8325631bd0d94a492d823b56b670fc8f3fefc32b959fec1` |
