# Scrub

A Mac app that replaces personal details in JSON, XML, CSV and text files with realistic stand-ins, before the file goes anywhere near an AI tool. Drop a file or paste text, review the result, then copy or save it.

Everything runs on the Mac. The app ships in the App Sandbox with no network entitlement, so macOS itself refuses any connection it tries to make; `scripts/prove-offline.sh` demonstrates that.

## How it works

- Finds personal details three ways: patterns (emails, phone numbers, cards, IBANs, secrets and more), Apple's on-device data detectors, and on-device name recognition.
- Replaces each real person, place or value with one consistent stand-in across the whole file.
- Re-checks the output and replaces anything that still matches an original.
- Keeps the file's structure: keys, columns, elements and formatting stay as they were.

Detection is statistical, so results say "Review before sharing", never "clean".

## Requirements

macOS 15 or later, Swift 6.2 or later (Xcode or the command line tools).

## Build and run

```sh
scripts/bundle.sh          # builds build/Scrub.app, signed ad hoc with the hardened runtime and App Sandbox
open build/Scrub.app
```

Set `SCRUB_SIGN_IDENTITY` to a Developer ID certificate name to sign for distribution.

## Test

```sh
swift test
scripts/prove-offline.sh   # control run gets out; the sandboxed run is refused by the kernel
```

Property tests take `SCRUB_PROPERTY_SEED` and `SCRUB_PROPERTY_CASES` (default 24) to reproduce or deepen a run.

## Layout

- `Sources/ScrubCore`: detection, stand-ins and the JSON, XML, CSV and text formats.
- `Sources/Scrub`: the SwiftUI app.
- `Sources/NetworkProbe`: the probe the offline proof runs.
- `Support`: Info.plist, entitlements and icon.
