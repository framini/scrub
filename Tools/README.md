# Tools

Scripts that make the files Scrub ships under `Sources/ScrubCore/Resources`
and the person scorer's weights in `Sources/ScrubCore/PersonScorer.swift`.
They are for retraining by hand only. None of them ships in Scrub, none runs
when Scrub is built (`scripts/bundle.sh` runs `swift build` on the Swift
sources alone), and none runs when Scrub runs. Building Scrub needs no Python
and nothing from the network.

| Folder | Makes | Reaches the network |
|---|---|---|
| `NameModel` | `NameModel.bin` | No. It trains on text generated from the name lists. |
| `AddressModel` | `AddressModel.bin`, `AddressModelWide.bin` | `fetch_data.py` downloads GeoNames postal files and US Census TIGER/Line street names. |
| `ContextModel` | `ContextModel.1.bin`, `ContextModel.2.bin` | `fetch_data.py` downloads the labelled training text at pinned revisions and checks each file's SHA-256; `train.py` and `prune.py` fetch the base encoder and its tokenizer at a pinned revision. |
| `NameLists` | `NameLists.txt` | `derive.py` downloads the SSA and Census name files and public-domain books, each checked against a digest. |
| `PersonScorer` | the weights in `PersonScorer.swift` | No. Python's standard library only. |

Each folder's README has the recipe, the data it learns from and a parity
check that the Swift code gives the same answers as the trained model. Each
folder with third-party Python packages pins them in its `requirements.txt`.
The sources and licences of the data and base model are in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

A retrained file changes its SHA-256, so it is used only once the checksum in
the Swift code is updated to match: a weight file swapped in on its own is
refused at load.
