# Security

A guide for reviewing Scrub: what ships, what it can reach, where its files
come from, and how each claim can be checked.

## What ships

`scripts/bundle.sh` builds `Scrub.app` from this repository alone:

| In the app | From |
|---|---|
| `Contents/MacOS/Scrub` | `Sources/Scrub` and `Sources/ScrubCore`, built by `swift build -c release` |
| `Contents/Resources/Scrub_ScrubCore.bundle` | the six files in `Sources/ScrubCore/Resources` (below) |
| `Contents/Info.plist`, `AppIcon.icns` | `Support` |
| `Contents/Resources/THIRD_PARTY_NOTICES.md` | [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) |

`Package.swift` declares no package dependencies. The code imports Apple's
frameworks only: Foundation, SwiftUI, AppKit, Accelerate, CryptoKit,
NaturalLanguage, UniformTypeIdentifiers, Observation, Synchronization, os and
Darwin. The build resolves nothing and downloads nothing.

`Sources/NetworkProbe` and `Tests` are test-only and are not in the app.
`Tools` holds the scripts that made the model files. They are used only to
retrain by hand, never at build or run time (see [`Tools/README.md`](Tools/README.md)).

## What it can reach

- **No network.** The app is signed with the hardened runtime and the App
  Sandbox and has no network entitlement ([`Support/Scrub.entitlements`](Support/Scrub.entitlements)),
  so the kernel refuses every connection. The code makes none.
  [`scripts/prove-offline.sh`](scripts/prove-offline.sh) shows it: one probe,
  signed with the same entitlements, gets out unsandboxed and is refused
  sandboxed.
- **Files the user picks.** Its only other entitlement is
  `files.user-selected.read-write`: it reads a file the user opens or drops
  and writes where the user saves. Input is capped at 50 MB.
- **Private saves.** A save is written to a fresh file created with mode
  `0600` and `O_EXCL`, synced, then moved into place
  (`Sources/ScrubCore/PrivateFile.swift`).
- **The clipboard.** It reads the clipboard only when the user pastes and
  writes to it only when the user copies. On Start over or quit it clears
  what it copied, if that is still there.
- **Nothing is kept.** The map from real values to stand-ins, the user's marks
  and edits live in memory for one job. Nothing is written to preferences,
  caches or logs. Its only log lines say a model file failed to load, with no
  user text.
- **Output a spreadsheet would run.** CSV cells starting with `=`, `@`, `+`
  or `-` (other than plain numbers) get a leading `'`.

## The model files

Scrub's detectors are code, Apple's system name tagger and data detector, and
four small models that run on the CPU through Accelerate. Each model file is
checked against a SHA-256 in the code before it is read. A file that is
missing or altered is not used, and the result says *Reduced coverage* and
names it.

| File | Size | SHA-256 (in) | What | Made by |
|---|---|---|---|---|
| `NameModel.bin` | 1.9 MB | `0a3ff56f…` (`NameModel.swift`) | A 1.6M-parameter network that reads a word and its neighbours and says whether it names a person | `Tools/NameModel`, from text generated with the name lists |
| `AddressModel.bin` | 2.0 MB | `68a0742d…` (`AddressModel.swift`) | A network that marks postal addresses in lines that hold a number | `Tools/AddressModel`, from generated addresses built on GeoNames and US Census TIGER/Line data |
| `AddressModelWide.bin` | 2.0 MB | `eda633fa…` (`AddressModel.swift`) | The same for lines with no number | as above |
| `ContextModel.1.bin`, `.2.bin` | 39.6 MB each | `7a403a65…` for both joined (`ContextModel.swift`) | A pretrained multilingual encoder (Multilingual-MiniLM-L12-H384), fine-tuned to tag personal details from the sentence around them. Split in two to keep each file under 50 MB | `Tools/ContextModel`, from public labelled text at pinned revisions and generated text |
| `NameLists.txt` | 0.7 MB | `de82406a…` (`NameLists.swift`) | First names, surnames and word frequencies, used as supporting evidence | `Tools/NameLists/derive.py`, from SSA and US Census name files and public-domain books |

The person scorer, a logistic regression over 25 signals, is 26 numbers in
`Sources/ScrubCore/PersonScorer.swift`, fitted by `Tools/PersonScorer/fit.py`.

Each `Tools` folder's README has the recipe, the data and a parity check that
the Swift code gives the same answers as the trained model. The data's and
base model's sources and licences are in `THIRD_PARTY_NOTICES.md`, which ships
in the app as those licences require. No user data and no private data was
used to train any of them, and the real-text documents the release gate
measures with are never used for training or tuning.

To check the shipped files match the code:

```sh
cd Sources/ScrubCore/Resources
shasum -a 256 NameModel.bin AddressModel.bin AddressModelWide.bin NameLists.txt
cat ContextModel.1.bin ContextModel.2.bin | shasum -a 256
```

## Reading hostile input

Everything a file holds is read as data, never run. JSON is read by Scrub's
own parser (`OrderedJSON.swift`), which keeps key order. XML is read by
Foundation's parser with external entities never loaded
(`XMLSerialization.swift`, `XMLDepth.swift`). JSON and XML nested deeper than
64 levels are refused before a tree is built, and input is capped at 50 MB.
The tests transform generated documents the ways real text arrives
(byte-order marks, UTF-16, zero-width and other hidden characters, formatting
that splits a word) and generate payloads over random seeds, and check that
nothing leaks and the output still parses (see *Test* in the
[README](README.md#test)).

## Release

`scripts/release.sh` runs the real-text gate, builds with a Developer ID
certificate, notarizes and staples the app and the disk image, and prints
`spctl` assessments and the image's SHA-256.

## What Scrub does not promise

Scrub finds personal data by reading it, and can miss some. The user reviews
every finding before saving, and can mark what it missed. The known gaps are
in [README › Limits](README.md#limits).

## Reporting

Report a security problem to the maintainer privately rather than in a public
issue.
