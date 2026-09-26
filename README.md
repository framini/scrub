<div align="center">

<img src="docs/images/icon.png" width="112" alt="Scrub app icon">

# Scrub

**Replace personal details in files with realistic stand-ins, before they go anywhere near an AI tool.**

Fully offline. Nothing you drop into Scrub leaves your Mac.

<a href="https://github.com/framini/scrub/releases/latest/download/Scrub.dmg"><strong>Download for macOS</strong></a>
· <a href="#install">Install</a>
· <a href="#how-it-works">How it works</a>
· <a href="#private-by-construction">Privacy</a>

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-1f4d3a)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-1f4d3a)
![App Sandbox, no network](https://img.shields.io/badge/App%20Sandbox-no%20network-1f4d3a)
![No dependencies](https://img.shields.io/badge/dependencies-none-1f4d3a)

<br>

<img src="docs/images/drop.png" width="860" alt="Scrub's drop screen: drop a file or paste text">

</div>

## Install

1. [Download the latest signed DMG](https://github.com/framini/scrub/releases/latest/download/Scrub.dmg) and open it.
2. Drag `Scrub.app` into Applications, then launch it.

That's it: no account, no setup, no permissions to grant. Scrub needs an Apple silicon Mac running macOS 15 or newer.

The app is signed with a Developer ID and notarized by Apple, so it opens without Gatekeeper warnings. Every version is on the [releases page](https://github.com/framini/scrub/releases). To check a download against its release notes:

```sh
shasum -a 256 ~/Downloads/Scrub.dmg
```

Scrub never checks for updates, since it has no network access. Download a newer DMG and drag it over the old app to update.

## Why

You want to paste a support ticket, a customer export or a log into an AI tool, but it's full of names, emails, phone numbers, cards and keys. Deleting them breaks the file; redacting them to `[REDACTED]` loses the shape the tool needs to be useful.

Scrub swaps each one for a believable stand-in instead. The same person gets the same stand-in everywhere in the file, emails still match their owner's name, and the file keeps its structure.

## See it work

### Free text

Names, emails, phone numbers and bank details in an email thread. The manager gets a different stand-in from the sender, and the signature matches the header.

<img src="docs/images/text.png" alt="A support ticket after scrubbing: names, emails, phone and IBAN replaced">

<details>
<summary>Original input</summary>

```text
From: Maria Gonzalez <maria.gonzalez@northwind.io>
Sent: Tuesday, 3 March

Hi team,

I was double charged on my card ending 4242 for invoice 20931. You can reach me
on +1 (415) 555-0132, or my manager Daniel Okafor at daniel.okafor@northwind.io.

Please send the refund to IBAN DE89 3704 0044 0532 0130 00.

Thanks,
Maria Gonzalez
```

</details>

### JSON

Nesting and non-personal values are kept; a key is only renamed when it holds personal data itself. Secrets become 24 random characters, keeping a known vendor prefix like `sk_live_`, so their length gives nothing away. Card numbers keep their network, length and grouping, and still pass the checksum. When anything is replaced the output is re-indented; when nothing is, you get the file back byte for byte.

<img src="docs/images/json.png" alt="A customer record after scrubbing: name, contact details, birth date, card and API key replaced">

<details>
<summary>Original input</summary>

```json
{
  "customer": {
    "id": "C-10482",
    "name": "Maria Gonzalez",
    "email": "maria.gonzalez@northwind.io",
    "phone": "+1 (415) 555-0132",
    "address": "1847 Valencia Street, San Francisco, CA 94110",
    "date_of_birth": "1986-04-12"
  },
  "payment": { "card": "4111 1111 1111 1111", "expires": "09/28" },
  "api_key": "sk_live_4eC39HqLyjWDarjtT1zdp7dc",
  "notes": "Maria asked to move her renewal to March. Call back after 3pm.",
  "plan": "Team",
  "seats": 12
}
```

</details>

### CSV

Spreadsheets get a table preview with replaced cells marked. Columns that aren't personal, like plan and signup date, are untouched.

<img src="docs/images/csv.png" alt="A signups spreadsheet after scrubbing: every name, email, phone and city replaced">

The sample files are in [`docs/samples`](docs/samples) if you want to try them yourself.

## How it works

1. **Finds personal details three ways:** patterns (emails, phone numbers, cards, IBANs, secrets and more), Apple's on-device data detectors, and on-device name recognition.
2. **Replaces them consistently:** each real person, place or value gets one stand-in across the whole file.
3. **Re-checks the output** for originals that slipped through, replaces them, and flags any it can't resolve as *left to review*.
4. **Keeps the structure:** nesting, columns and elements stay as they were, and values are replaced in place.

Results say *Review before sharing*, never *clean*: detection is statistical, and the counts show what Scrub found and replaced, not proof of what's left.

## Private by construction

- **No network, enforced by macOS.** Scrub ships in the App Sandbox without the network entitlement, so the kernel refuses any connection it tries to make. [`scripts/prove-offline.sh`](scripts/prove-offline.sh) shows it: the same probe gets out when unsandboxed and is refused when signed with Scrub's entitlements.
- **Nothing is kept.** The map from real values to stand-ins lives in memory for one job only.
- **Private saves.** Saved files are readable by your user account only.
- **Clipboard cleanup.** Start over or quit, and Scrub takes back what it copied if it's still on the clipboard.
- **Formulas defused.** CSV cells that a spreadsheet would run as a formula (starting with `=`, `@`, `+` or `-`, other than plain numbers) get a leading `'`, so they open as text.

## Limits

- Files up to 50 MB of UTF-8 text (XML may also be UTF-16).
- JSON and XML nested up to 64 levels. XML with a DOCTYPE or entity declarations is refused.
- The preview shows the first 200,000 characters or 500 table rows. Copy and Save always give the whole result.
- Detection finds what it recognises. A value only counts as a secret when it looks like one, or sits under a key like `password` or `token`. Blank values and `true`/`false` under those keys are left as they are.

Not covered, so check for these yourself:

- Identity numbers from outside the US in free text. They are caught under keys like `national_id`.
- A first name on its own that Scrub has never seen with a surname, unless it signs off a message, like "Maria" on the line after "Thanks,".
- Values split across XML markup, as in `alice<em>@</em>example.com`.
- Personal data that appears only in XML element or attribute names, unless the same person also appears in the data. Runs of seven or more digits in JSON keys and XML names are always replaced.
- Record identifiers such as `customer_id` values, which are kept so records still line up.

## Keyboard

| | |
|---|---|
| <kbd>⌘</kbd> <kbd>V</kbd> | Paste text to scrub |
| <kbd>⌘</kbd> <kbd>C</kbd> | Copy the selection, or the whole result |
| <kbd>⌘</kbd> <kbd>S</kbd> | Save the result |
| <kbd>esc</kbd> | Cancel, or start over |

## Build from source

Needs macOS 15 or later and Swift 6.2 or later (Xcode or the command line tools).

```sh
scripts/bundle.sh          # builds build/Scrub.app with the hardened runtime and App Sandbox
open build/Scrub.app
```

It signs ad hoc by default. To build a release DMG like the one above, signed, notarized and stapled:

```sh
SCRUB_SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh   # uses the notarytool keychain profile scrub-notary, or SCRUB_NOTARY_PROFILE
```

## Test

```sh
swift test                 # unit, regression and property-based tests
scripts/prove-offline.sh   # the offline proof above
```

Property tests take `SCRUB_PROPERTY_SEED` and `SCRUB_PROPERTY_CASES` (default 24) to reproduce a failure or run deeper.

## Layout

| Path | What |
|---|---|
| `Sources/ScrubCore` | Detection, stand-ins, and the JSON, XML, CSV and text formats |
| `Sources/Scrub` | The SwiftUI app |
| `Sources/NetworkProbe` | The probe the offline proof runs |
| `Support` | Info.plist, entitlements and icon |
| `docs` | README screenshots and sample files |
