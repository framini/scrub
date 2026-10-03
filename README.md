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

Scrub swaps each one for a believable stand-in instead. The same person gets the same stand-in everywhere in the file, emails and usernames still match their owner's name, an address's city, state and ZIP code still belong together, and the file keeps its structure.

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

Nesting and non-personal values are kept; a key is only renamed when it holds personal data itself. Secrets become 24 random characters, keeping a known vendor prefix like `sk_live_`, so their length gives nothing away; short numeric codes like a CVV or PIN stay digits of the same length. Card numbers keep their network, length and grouping, and still pass the checksum. When anything is replaced the output is re-indented; when nothing is, you get the file back byte for byte.

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

1. **Finds personal details in layers**, each catching what the others miss:
   - **Rules** for anything with a shape: emails, phone numbers, cards, IBANs, secrets, addresses, and values written after a label in prose, like `born 14 March 1987`, `Passport no. 553901274` or `api key: …`.
   - **Apple's on-device** data detectors and name tagger.
   - **Three small models of Scrub's own**, all shipped inside the app:
     - a 2 MB name model that reads the letters of a word, for names the tagger doesn't know;
     - a 2 MB address model that reads the lines around a number, for postal addresses the rules and Apple's detector miss: another country's format (`Lindenhofer Straße 48a⏎70178 Stuttgart`, `ul. Kwiatowa 7 m. 12, 30-389 Kraków`), a flat or a PO box over its town, a signature's address on one line, a street in a sentence with no postcode. It reads only text with a number in it, and replaces each address as one unit;
     - a 79 MB context model that reads the whole sentence, for people, places, an employer named beside a person, social handles, names in non-Latin scripts in English text, and IDs, secrets and birth dates the rules missed.
   - **A person only a model read counts when something else agrees.** The context model's guess needs a second sign that it is a name: the name model calling it one, a listed first name or surname that is no ordinary word, a title, a greeting or sign-off, or a verb it is the subject of. A small scorer, 25 weights fitted on generated text and checked on openly licensed real text, then weighs every sign together, drops the guesses it doubts, and gives each kept one a confidence. A word after "the" or before a version number, a town someone moved to, part of a company's name or a handle, and a single word opening a sentence that only the context model reads as a name ("Corvane was founded in 1985") are not taken for people.
   - **Each name, followed through the file.** Once a full name is found, its parts and other written forms are found everywhere else: "Odalys" alone, "O. Ferriter", "Ferriter, Odalys", "FERRITER", a greeting or a sign-off. Public-domain lists of first names and surnames help decide what is a name, but never on their own: a word on a list still needs something around it that marks a name. A word a dictionary holds and no list of names does, like "Refund" read as a surname, is followed only where it is written as a name, never in lowercase or opening a sentence.
2. **Replaces them consistently:** each real person, place or value gets one stand-in across the whole file, however it's written. "Ms Ferriter" and "Odalys" become the same stand-in person, with a first name that fits the title. A title never joins a first name that is clearly of the other sex: "Ms Okafor" and "Mateus Okafor" stay two people, with one stand-in surname, and Mateus keeps a man's first name. A first name given to either sex, like "Jordan", still joins. A title or a rank stays as written before the stand-in: "Corporal Haddleton" and "Detective Inspector Quayle" keep their ranks.
3. **Checks the output before it finishes.** It sweeps the output for every original it replaced, as written, and runs the detectors over it again. Detectors that read the same words again find little new, so a last check, the *leak gate*, reads the output with what they didn't have: the values already replaced. It looks for those values written another way and still there:
   - a name in capitals, split over two lines or by a hyphen (`Fer-⏎riter`), or inside a handle or login: `@odalysf`, `odalys.f`, `oferriter`, `ferriterodalys`, `ferriter99`;
   - a phone or ID number with other separators or none (`4158672290` for `(415) 867-2290`), and its last four digits after a label like "ending in" or "last four";
   - an email in capitals, or its local part on its own ("user quillpen77").

   Each is replaced with the stand-in its original got, in the variant's own shape: if Odalys Ferriter became Maren Holt, `@odalysf` becomes `@marenh` and `ferriter99` a handle starting `holt`. A name's part is looked for only when it is at least four letters and no ordinary or dictionary word, so "Will", "Rose" and "Mark" are never hunted this way. The check also flags card numbers, IBANs and Social Security numbers that pass their check and are still as written, unless they're filed under an order, invoice or ticket.

   It runs again after every round of replacements until a round finds nothing new, up to three rounds, each fixing a bounded number of variants in proportion to the text. What it only suspects, a variant inside a link, and anything still there when it stops are left as written and put to you in step 5, never dropped. It doesn't prove the output is clean: it makes sure a scrub never finishes quietly with a leak Scrub can recognise.
4. **Keeps the structure:** nesting, columns and elements stay as they were, and values are replaced in place.
5. **Asks before you share** about the replacements it's least sure of: people only a model found that the scorer is least sure of, other values only a model found, and places only Apple's tagger guessed. It also asks about everything the last check left as written, showing the stand-in each would take. You see each one in context and choose: keep a replacement or leave the original, and replace a suspect or leave it. Either choice covers every place the value appears, and every other stand-in stays as it was.

Results say *Review before sharing*, never *clean*: detection is statistical, and the counts show what Scrub found and replaced, not proof of what's left.

## Private by construction

- **No network, enforced by macOS.** Scrub ships in the App Sandbox without the network entitlement, so the kernel refuses any connection it tries to make. [`scripts/prove-offline.sh`](scripts/prove-offline.sh) shows it: the same probe gets out when unsandboxed and is refused when signed with Scrub's entitlements.
- **Models run on your Mac.** Scrub's own models ship inside the app and run on the CPU. Nothing is downloaded, at install or ever. Each model file is checked against a SHA-256 built into the code before it loads. If a file has been altered, Scrub won't use it and falls back to rules and Apple's detectors.
- **Nothing is kept.** The map from real values to stand-ins lives in memory for one job only.
- **Private saves.** Saved files are readable by your user account only.
- **Clipboard cleanup.** Start over or quit, and Scrub takes back what it copied if it's still on the clipboard.
- **Formulas defused.** CSV cells that a spreadsheet would run as a formula (starting with `=`, `@`, `+` or `-`, other than plain numbers) get a leading `'`, so they open as text.

## Limits

- Files up to 50 MB of UTF-8 text (XML may also be UTF-16).
- JSON and XML nested up to 64 levels. XML with a DOCTYPE or entity declarations is refused.
- The preview shows the first 200,000 characters or 500 table rows. Copy and Save always give the whole result.
- Long text takes a while, because the context model reads every sentence: a few megabytes of prose can take several minutes, and a 40,000-row spreadsheet about a minute. Progress shows as it goes, and cancelling stops promptly.
- Detection finds what it recognises. A value counts as a secret when it looks like one, or sits under a key that names one, like `password`, `db_password`, `api_token` or `webhook_secret`. Blank values and `true`/`false` under those keys are left as they are.
- Field names help in pasted text too: in a JSON body inside a curl command or a log line, an object literal in code, or YAML, pairs like `"family_name": "Charleston"`, `family_name: 'Charleston'` or `family_name: Charleston` are read as that field. Types in code, like `email: string`, are left alone.
- Fields are read by their parts and qualifiers: a plain `value` or `data` key takes its parent's meaning, so `"id_number": {"value": "123456789"}` stays a nine-digit ID; `"name": {"first": …}`, `"phones": [{"number": …}]` and `"dob": {"year": …}` are read as the part; lists like `names` or `emails` and keys like `billing_email` or `applicant_dob` count as their field, but counts like `num_family_names` don't. Form fields (`{"name": "ssn", "value": …}`), FHIR resources and flattened CSV headers like `billing.address.city` are read the same way.
- A bare `name` key is read as a person only when its record also holds personal details like an email, phone or birth date, when it sits under a key like `customers` or `manager`, or when it uses a common first or last name. Otherwise, as for an account called `Everyday Checking`, the value goes through the usual detection.
- A value that can't be what its field names is left to the usual detection: a status like `"first_name": "match"` or `"date_of_birth": "NO_MATCH"`, or a score like `"surname": 0.86`, stays as it is.
- Values under keys like `created_at`, `timezone`, `country` or `request_id` are read as written: a Unix time isn't a phone number, and `America/Chicago` isn't a place. A time zone beside an address moves with it.
- The names of published standards and catalogued flaws, like `RFC4716`, `ISO 8601`, `IEEE 802.11` or `CVE-2021-44228`, are left as written: they read the same for everyone, so they are nobody's ID.
- Stand-ins keep the original's type: a date keeps its format (`April 21, 2003`, `16 JUL 1982`), a number stays a number of the same length so pasted JSON still parses, `Apt 2B` stays an apartment line, `4821 Juniper Hollow Rd` stays a road, a coordinate keeps its precision, a masked `***-**-7784` stays masked, and an IPv6 address stays IPv6. A phone number keeps its layout, with a real area code and a line from the fictional 555-0100 to 0199 range; one from outside North America keeps its country code.
- Stand-ins that belong together agree. An address's city, state or province, postcode, coordinates and time zone, and the area code of the phone beside it, come from one real place in the same country (the US, Canada, the UK or Australia), in a different state. A one-line address like `4821 Juniper Hollow Rd, Tacoma, WA 98402` becomes one line from that place, matching the separate fields. `billing_city` and `shipping_city` in one record are two addresses.
- An address keeps its layout: its lines, units, kind of street and country stay where they were. `Flat 3, 27 Pellow Gardens, Bristol BS6 5QR` becomes, say, `Flat 7, 12 Maple Gardens, London NW3 8ST`, and `Keizersgracht 418-2, 1016 GC Amsterdam` becomes `Duingracht 602-6, 3011 WL Rotterdam`. In 23 other countries, from Ireland and Germany to Brazil and Japan, the city is another of the same country with a postcode in its own format.
- A birth year moves by one to eight years, and `birth_year` and `age` fields move with it, so age brackets and estimates beside them still read true. Last four digits (`ssn_last4`, a card's `last4`, or "ending in 7784" in a sentence) end the stand-in of the number they come from when the file holds that number in full. Initials, usernames and emails follow the stand-in name. A first name fits a `gender`, `sex` or `title` field, or a title like `Ms` used for that person anywhere in the file.
- A plain run of digits that could be a phone number, like `912355201` under `ein`, keeps its digits instead of becoming `+1 555-…`, since it may as well be an account, tax or ID number.
- Names are found by the on-device recogniser, by the field they sit in (`name`, `assigned_to`, `manager`, `Customer:`), before an email address, as in `Priya Raghunathan <priya@example.com>` or `Priya Raghunathan (priya@example.com)`, quoted or written last name first, and before a mailing address, as in `Ship to Priya Raghunathan, 12 Pine St, …`. In role fields a name can also be `Raghunathan, Priya`, carry a note like `(Support)`, or be a common first name alone. Values with team words, like `Platform Team` or `Support Team`, are left as they are.
- Card numbers keep their network, length and checksum when they sit in a field. In free text a card is always replaced, but can get a different kind of stand-in.

Not covered, so check for these yourself:

- Identity numbers from outside the US in free text, unless a label comes before them, like `Passport no.` or `NHS number`. They are always caught under keys like `national_id`.
- Some names in running text, most often in casual writing. These include a nickname, a first name on its own that never appears with a surname and isn't in a greeting or sign-off, a lowercase name no list holds, and a name that is also an ordinary word with nothing around it marking a name, like "Mark" or "Ken" at the start of a line. On real, human-labelled text, Scrub catches about 90 in 100 names in email and 95 in 100 in court judgments, but only about half to seven in ten in social media posts.
- A handle or login built from a name in a way the last check doesn't know, like a nickname or a part shorter than four letters inside it ("dalys_f", "ana.r"), unless a detector reads it as a handle.
- Names written in lowercase, unless the same person's full name appears elsewhere in the file. Then its lowercase parts are caught too ("thanks odalys"), as long as they are at least four letters and aren't ordinary words.
- Some names are also ordinary words, and the word can occasionally be replaced too ("christian holiday"). So can a character, a show or a product written like a person's name in casual writing.
- Places in casual writing, like a town with its county or a hashtag, are often missed.
- Pasted XML with a DOCTYPE is scrubbed as plain text, so its field names don't help detection.
- Values split across XML markup, as in `alice<em>@</em>example.com`.
- Personal data that appears only in XML element or attribute names, unless the same person also appears in the data. Runs of seven or more digits in JSON keys and XML names are always replaced.
- Record identifiers such as `customer_id` values, which are kept so records still line up.
- Addresses outside the US, Canada, the UK and Australia keep their shape, but their parts aren't matched to one real place. So are cities written in running text without a state or postcode after them.
- Addresses written all in lowercase, addresses with no number at all (a house name and a village), and addresses in non-Latin scripts are often missed. So is a building or a district name the address model leaves outside the address, like a name before `Torre` or `Edificio`.
- Ages with no birth date in the same file stay as they are.

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

Everything the build needs is in the repository, including the model weights, which are plain files under `Sources/ScrubCore/Resources` (the context model is split in two to keep each file under 50 MB). There is nothing to download and no package to resolve.

It signs ad hoc by default. To build a release DMG like the one above, signed, notarized and stapled:

```sh
SCRUB_SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh   # uses the notarytool keychain profile scrub-notary, or SCRUB_NOTARY_PROFILE
```

### Retrain the models

The models are trained from scripts in `Tools`, with their Python requirements pinned. The person scorer's weights are fitted by `Tools/PersonScorer/fit.py`, which needs only Python's standard library. You only need this to retrain them, not to build or run Scrub. Each model's folder has a README with the recipe, the data it learns from, and a parity check that the Swift code gives the same answers as the trained model. Licences and attributions for the base model, the training data and the name lists are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Test

```sh
swift test                 # unit, regression and property-based tests
scripts/prove-offline.sh   # the offline proof above
```

Property tests take `SCRUB_PROPERTY_SEED` and `SCRUB_PROPERTY_CASES` (default 24) to reproduce a failure or run deeper. The payload tests generate realistic API payloads (signups, identity checks, payments, form submissions, webhooks, audit logs, HR and FHIR records), render each as JSON, XML, CSV, pasted JSON, a curl command, a log line, JavaScript, Python and YAML, and as a support note or mailing label, and check every field: personal values replaced by stand-ins of the same type, everything else unchanged, the output still parses, and values that belong together still agree (an address is one real place with its time zone and area code, an email and username follow the name, an age follows the birth date, last digits end their number). `SCRUB_PAYLOAD_REPORT=/path` writes an example input for each kind of failure.

Two benchmarks track detection by kind of gap, through a text file, a JSON field and a CSV column at once: `NameGaps` for names (lowercase, non-Latin, sign-offs, names that are also words, and more) and `PIIGaps` for values written in prose (birth dates, labelled IDs, secrets, post office boxes, addresses in other countries' formats). Each guards a `baseline.json`, so no category can score lower than it did. After an improvement, `SCRUB_GAPS_RECORD=1` or `SCRUB_PII_GAPS_RECORD=1` records the new baseline. `SCRUB_GAPS_SCORER=off` and `SCRUB_PII_GAPS_SCORER=off` measure the person scorer's hand rules alone.

Real text is measured separately. `SCRUB_REAL_CORPUS=/dir swift test --filter RealCorpus` runs Scrub over human-labelled documents in JSONL format and reports, per label, how much it caught and how many other words it changed. The labelled text stays outside the repository and is never used for training, so it stays a fair test. The test file documents the format and its other switches.

`SCRUB_ORACLE=/dir` with `SCRUB_ORACLE_RECORD=1` saves Scrub's output for a fixed corpus of generated documents. Run it again with only `SCRUB_ORACLE=/dir` and it fails on the first byte that differs. Use it to check that a speed change leaves every output exactly as it was.

## Layout

| Path | What |
|---|---|
| `Sources/ScrubCore` | Detection, stand-ins, and the JSON, XML, CSV and text formats |
| `Sources/ScrubCore/Resources` | The model weights and name lists, each checked by SHA-256 before use |
| `Sources/Scrub` | The SwiftUI app |
| `Sources/NetworkProbe` | The probe the offline proof runs |
| `Tools` | Training and export scripts for the models, the script that fits the person scorer, and the script that builds the name lists |
| `Support` | Info.plist, entitlements and icon |
| `docs` | README screenshots and sample files |
