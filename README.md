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
     - two 2 MB address models, for postal addresses the rules and Apple's detector miss: another country's format (`Lindenhofer Straße 48a⏎70178 Stuttgart`, `ul. Kwiatowa 7 m. 12, 30-389 Kraków`), a flat or a PO box over its town, a signature's address on one line, a street in a sentence with no postcode. The first reads the lines around a number. The second also reads addresses written all in lowercase (`14 rookery lane, leeds ls6 2ab`) and addresses with no number (`Flat B, The Old Rectory, Little Hadham`, `Hauptstraße, Berlin-Mitte`), on the few lines with no number that hold a kind of street, a building or a unit. Scrub keeps what either finds and replaces each address as one unit. A lowercase address needs a postcode, a unit's number, a place Scrub knows or words before it that say an address follows (`she moved to 12 rue des lilas`), and one with no number needs a street, building or unit beside another piece, so a sentence that only names a street is never replaced on a guess: a street or a house named alone after such words (`send it to Lindenhofweg`), or read as a place by the context model (`lives at Mill Lane`), is asked about in step 5 instead;
     - a 79 MB context model that reads the whole sentence, for people, places, an employer named beside a person, social handles, names in non-Latin scripts in English text, and IDs, secrets and birth dates the rules missed. It reads long text in overlapping windows of 128 pieces, and the first window to read a piece decides it.
   - **A person only a model read counts when something else agrees.** The context model's guess needs a second sign that it is a name: the name model calling it one, a listed first name or surname that is no ordinary word, a title, a greeting or sign-off, or a verb it is the subject of. A small scorer, 25 weights fitted on generated text and checked on openly licensed real text, then weighs every sign together, drops the guesses it doubts, and gives each kept one a confidence. A word after "the" or before a version number, a town someone moved to, part of a company's name or a handle, and a single word opening a sentence that only the context model reads as a name ("Corvane was founded in 1985") are not taken for people.
   - **Each name, followed through the file.** Once a full name is found, its parts and other written forms are found everywhere else: "Odalys" alone, "O. Ferriter", "Ferriter, Odalys", "FERRITER", a greeting or a sign-off. Public-domain lists of first names and surnames help decide what is a name, but never on their own: a word on a list still needs something around it that marks a name. A word a dictionary holds and no list of names does, like "Refund" read as a surname, is followed only where it is written as a name, never in lowercase or opening a sentence.
2. **Replaces them consistently:** each real person, place or value gets one stand-in across the whole file, however it's written. "Ms Ferriter" and "Odalys" become the same stand-in person, with a first name that fits the title. A title never joins a first name that is clearly of the other sex: "Ms Okafor" and "Mateus Okafor" stay two people, with one stand-in surname, and Mateus keeps a man's first name. A first name given to either sex, like "Jordan", still joins. A title or a rank stays as written before the stand-in: "Corporal Haddleton" and "Detective Inspector Quayle" keep their ranks.
3. **Checks the output before it finishes.** It sweeps the output for every original it replaced, as written, and runs the detectors over it again. Detectors that read the same words again find little new, so a last check, the *leak gate*, reads the output with what they didn't have: the values already replaced. It looks for those values written another way and still there:
   - a name in capitals, split over two lines or by a hyphen (`Fer-⏎riter`), or inside a handle or login: `@odalysf`, `odalys.f`, `oferriter`, `ferriterodalys`, `ferriter99`;
   - any of these in a link's part written percent-encoded, read as it reads (`?q=%46erriter`, `%46er%E2%80%8Briter`);
   - a phone or ID number with other separators or none (`4158672290` for `(415) 867-2290`), and its last four digits after a label like "ending in" or "last four";
   - an email in capitals, or its local part on its own ("user quillpen77").

   Each is replaced with the stand-in its original got, in the variant's own shape: if Odalys Ferriter became Maren Holt, `@odalysf` becomes `@marenh` and `ferriter99` a handle starting `holt`. A name's part is looked for only when it is at least four letters and no ordinary or dictionary word, so "Will", "Rose" and "Mark" are never hunted this way. The check also flags card numbers, IBANs and Social Security numbers that pass their check and are still as written, unless they're filed under an order, invoice or ticket.

   It runs again after every round of replacements until a round finds nothing new, up to three rounds, each fixing a bounded number of variants in proportion to the text. What it only suspects, a variant inside a link, and anything still there when it stops are left as written and put to you in step 5, never dropped. It doesn't prove the output is clean: it makes sure a scrub never finishes quietly with a leak Scrub can recognise.
4. **Keeps the structure:** nesting, columns and elements stay as they were, and values are replaced in place.
5. **Asks before you share** about the replacements it's least sure of: people only a model found that the scorer is least sure of, other values only a model found, places only Apple's tagger guessed, and an age or last four digits that more than one person nearby could own. A value is as sure as its least sure place, so one doubtful mention is enough to ask. It also asks about what it left as written:
   - everything the last check suspects, showing the stand-in each would take;
   - names it isn't sure enough to replace but can't ignore: a guess only a model made that nothing else in the text agrees with ("Looks like a name, but nothing else in the text agrees"), and a street or a house named on its own. These start on *Leave*.

   While any wait, a strip above the preview says how many, with *Check now*. You see each one in context, with the reason, and choose: keep a replacement or leave the original, and replace a suspect or leave it. A choice covers every place the value appears, or you can choose place by place; every other stand-in stays as it was. Copy, ⌘C on a selection and Save all wait for this check. The preview can always be selected and read, but a selection is copied, dragged out or sent to a service only once the check is done; trying sooner opens it.
6. **Lets you fix what it got wrong.** Select anything Scrub missed in the preview, in the text or in a table cell, and press ⌘E, click *Replace* under the preview, or right-click it. Scrub guesses what kind of value it is (a name, email, phone, address, place, username, employer, ID or secret) and you can pick another. A selection that cuts into a word takes the whole word, and one over several lines of JSON or XML takes the values, not the keys or tags. The value is replaced everywhere in the file, with its variants: in any case, with a possessive, a name with its initial or last name first, a name's part alone, and handles and email local parts built from it, also where they are split by markup or a hidden character or percent-encoded in a link, which gets its stand-in encoded the same way. A value that already has a stand-in elsewhere keeps it, and so does a name's part: marking "Ysolde" beside a replaced "Varrick" makes one stand-in person. Click a stand-in and the bar under the preview becomes its editor: *For “Odalys Ferriter” · 3 places*, the kind it's read as, and what replaces it. Pick another kind and the value gets a fresh stand-in of that kind, the one marking it as that kind would give. Or type your own replacement and press ⏎; esc closes the editor and changes nothing. A name typed for a person reaches the rest of them: typing `Jane Roe` for Odalys Ferriter also turns "Odalys" into "Jane", "Ms Ferriter" into "Ms Roe", "Ferriter" into "Roe" and `odalys.ferriter@…` into `jane.roe@…` on the same stand-in domain, and a handle Scrub built from her name follows too. A person's value changed to another kind leaves them, and their other forms keep their stand-ins; a replacement typed for any other kind reaches that value's places only. A replacement is refused, with the reason beside it, when it's empty, holds the value it replaces (in any case, with or without accents), or holds another value Scrub found or you marked, as a word of three letters or more. Nothing of a refused one is written. Each is written as its place needs: escaped in JSON and XML, quoted in CSV, percent-encoded in a link. *Keep original*, in the editor or with ⌘E, puts the original back everywhere instead; your own marks are underlined, and offer *Remove mark*.

   The **Values panel** (⇧⌘L, or *Values* in the footer) lists every value under the preview: its original, kind, stand-in, places, and whether it's replaced, left as written, still to check or marked by you. Search it by original or stand-in, filter it by kind or status, or show only *Your changes*, which the footer's count of what you marked, kept or edited opens. Select a row and the preview scrolls to its first place and shows it, with the editor open for it. ↑ and ↓ move from row to row (⇧ to select several, ⌘ to jump to the first or last). ⌘-click or ⇧-click several to change their kind, keep their originals or replace them again at once, and choose one value's places one by one with *Place by place…*. It stays quick with thousands of values.

   Each change says under the preview how many places it reached, with *Undo*; ⌘Z and ⇧⌘Z step back and forward through your marks, edits, kept originals and review choices, and undoing a review asks for it again before anything leaves. Marks and edits are applied to the scrub as made without running the detectors again, so the same file, marks, edits and choices always write the same result, and Copy and Save always include them, waiting while one is written in. They last until you start over; nothing about them is saved.

Results say *Review before sharing*, never *clean*: detection is statistical, and the counts show what Scrub found and replaced, not proof of what's left.

## Private by construction

- **No network, enforced by macOS.** Scrub ships in the App Sandbox without the network entitlement, so the kernel refuses any connection it tries to make. [`scripts/prove-offline.sh`](scripts/prove-offline.sh) shows it: the same probe gets out when unsandboxed and is refused when signed with Scrub's entitlements.
- **Models run on your Mac.** Scrub's own models ship inside the app and run on the CPU. Nothing is downloaded, at install or ever. Each model file is checked against a SHA-256 built into the code before it loads. If a file is missing or has been altered, Scrub won't use it and runs without it, and the result says *Reduced coverage* and names what didn't load.
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
- An address-line field with no number (`"line1": "the old rectory, church lane"`) is replaced with the rest of its address whenever its record's city, state or postcode is; a note there, like `same as billing`, stays.
- Stand-ins that belong together agree. An address's city, state or province, postcode, coordinates and time zone, and the area code of the phone beside it, come from one real place in the same country (the US, Canada, the UK or Australia), in a different state. A one-line address like `4821 Juniper Hollow Rd, Tacoma, WA 98402` becomes one line from that place, matching the separate fields. `billing_city` and `shipping_city` in one record are two addresses.
- An address keeps its layout: its lines, units, kind of street and country stay where they were. `Flat 3, 27 Pellow Gardens, Bristol BS6 5QR` becomes, say, `Flat 7, 12 Maple Gardens, London NW3 8ST`, and `Keizersgracht 418-2, 1016 GC Amsterdam` becomes `Duingracht 602-6, 3011 WL Rotterdam`. In 23 other countries, from Ireland and Germany to Brazil and Japan, the city is another of the same country with a postcode in its own format. An address written in lowercase gets a stand-in in lowercase, and one with no number gets none: `Hauptstraße, Berlin-Mitte` becomes another German street with no number beside another town.
- A birth year moves by one to eight years, and `birth_year` and `age` fields move with it, so age brackets and estimates beside them still read true. An age in a birth date's own record, or said after it in the same sentence (`born on 14 March 1987 and is 38`), moves by as many years, even when the file was written years before the scrub. Last four digits (`ssn_last4`, a card's `last4`, or "ending in 7784" in a sentence) and a masked number (`***-**-7784`, `xxxx7784`) end the stand-in of the number they come from when the file holds that number in full. Each follows the value in its own record (a JSON object, a CSV row or a flattened object in it like `spouse.dob`, an XML element) or, in prose, its own sentence or paragraph, so two people whose SSNs end alike keep their own endings. One date written two ways keeps one stand-in day, and a `birth_month` follows its record's date. Where two people could own the same ending or age and nothing says whose, it follows the first and review asks. Initials, usernames and emails follow the stand-in name. A first name fits a `gender`, `sex` or `title` field, or a title like `Ms` used for that person anywhere in the file.
- A plain run of digits that could be a phone number, like `912355201` under `ein`, keeps its digits instead of becoming `+1 555-…`, since it may as well be an account, tax or ID number.
- Record IDs that name a person or their account (`customer_id`, `patient_id`, `member_ref`, an `id` with a person's prefix like `cus_` or inside a customer's object, a `customer` field that refers to one, or any ID that spells out a name, email or phone number like `cus_odalys_ferriter`) get a stand-in of the same shape: a type prefix kept, the same length and kinds of character. A prefix is kept only when it is a type's code (`cus_`, `usr-`, `E-`, `INV-`), never when it is a name or the first word of a slug: `odalys-ferriter` is replaced whole, and so is `pat-ferriter1987` or `pat_ZqybnpAzukkun` in a file that names a Pat. An ID made of a name right after the word for whose it is (`account Quillmere_Tavish`) is found in prose too. The same ID gets the same stand-in wherever it appears, in other records, fields that refer to it, links and prose, so joins still work. Technical identifiers (request and trace IDs, UUIDs with no person around them, version hashes, SKUs, order and invoice numbers) stay as written.
- In links, the parts that name someone are replaced and the link stays valid: query values under a personal key (`?email=…&name=…&phone=…`, also in a `#fragment`, and in a route's own query like `#/search?email=…`), tokens and signatures (`token=`, `access_token=`, `sig=`, `X-Amz-Signature=`), a path segment under a collection of people (`/users/odalys.ferriter`, `/u/48213177`, `/~odalys`, also written encoded like `/%75sers/…`), a handle anywhere in the path (`/@odalysferriter`) and the user name before the host. Each is read decoded (`%40`, `+` for a space) and written back encoded the same way, with the stand-in the same value takes elsewhere in the file. A link that names no one (a page, a short link like `t.co/…`) stays as written, and so does a segment under people that names a part of the site (`/users/sign_in`, `/authors/id/…`) or a file it serves (`/user/default.asp`, `/users/index.html`), or is two letters long, and a name inside a host name is left to review.
- Text is read as a reader sees it: a zero-width space or joiner, a soft hyphen or a no-break space inside a name, email or number doesn't hide it, and neither does formatting inside a word (`Odal**ys**`, `<b>Odal</b>ys`). The stand-in drops the hidden characters and keeps the formatting. In an XML file, an element's text that runs around inline elements is read whole (`<note>Spoke with <i>Odal</i>ys Ferriter…</note>`, `alice<em>@</em>example.com`), and each stand-in word goes where its original's first piece was. A field inside that text stays a field, whatever text sits beside it: an element named for what it holds (`<account>Active<password>…</password></account>`), one an attribute names (`<data name="national_id">`, even on formatting), and a `<name>` in a person's record (`<customer>Active<name>…</name></customer>`).
- Names are found by the on-device recogniser, by the field they sit in (`name`, `assigned_to`, `manager`, `Customer:`), before an email address, as in `Priya Raghunathan <priya@example.com>` or `Priya Raghunathan (priya@example.com)`, quoted or written last name first, and before a mailing address, as in `Ship to Priya Raghunathan, 12 Pine St, …`. In role fields a name can also be `Raghunathan, Priya`, carry a note like `(Support)`, or be a common first name alone. Values with team words, like `Platform Team` or `Support Team`, are left as they are, and so is a team's or a list's mailbox (`ops-team@…`, `billing@…`, `no-reply@…`): it keeps its name and its local part, and only its domain changes, as everyone's does. A name in capitals counts beside a first name, a title or a greeting (`Hi JINX,`, `Julie BEET`, `Ms BEET`) and keeps its capitals; acronyms like `API`, `CEO` or `NASA` stay. A verb that opens an instruction (`Call Odalys on…`, `Ask Brisa`) is never part of the name after it, and marks one.
- Card numbers keep their network, length and checksum when they sit in a field. In free text a card is always replaced, but can get a different kind of stand-in.

Not covered, so check for these yourself:

- Identity numbers from outside the US in free text, unless a label comes before them, like `Passport no.` or `NHS number`. They are always caught under keys like `national_id`.
- Some names in running text, most often in casual writing. These include a nickname, a first name on its own that never appears with a surname and isn't in a greeting or sign-off, a lowercase name no list holds, and a name that is also an ordinary word with nothing around it marking a name, like "Mark" or "Ken" at the start of a line. On real, human-labelled text, Scrub catches about 90 in 100 names in email and 95 in 100 in court judgments, but only about half to seven in ten in social media posts.
- A handle or login built from a name in a way the last check doesn't know, like a nickname or a part shorter than four letters inside it ("dalys_f", "ana.r"), unless a detector reads it as a handle.
- Names written in lowercase, unless the same person's full name appears elsewhere in the file. Then its lowercase parts are caught too ("thanks odalys"), as long as they are at least four letters and aren't ordinary words.
- Some names are also ordinary words, and the word can occasionally be replaced too ("christian holiday"). So can a character, a show or a product written like a person's name in casual writing.
- Places in casual writing, like a town with its county or a hashtag, are often missed.
- Pasted XML with a DOCTYPE is scrubbed as plain text, so its field names don't help detection.
- Values split across XML elements that hold no text of their own beside them, as in `<first>Odal</first><last>ys</last>`: each element's text is read on its own.
- Personal data that appears only in XML element or attribute names, unless the same person also appears in the data. Runs of seven or more digits in JSON keys and XML names are always replaced.
- Addresses outside the US, Canada, the UK and Australia keep their shape, but their parts aren't matched to one real place. So are cities written in running text without a state or postcode after them.
- Addresses in non-Latin scripts are not read. Addresses written all in lowercase or with no number at all (a house name and a village) are read, but less reliably than written ones: on handwritten cases, about four in five lowercase ones and two in three numberless ones are fully replaced. A lowercase one with no postcode, unit number or known place, and no words before it that say an address follows (`meet me at 12 rue des lilas`), is left as written on purpose, and a numberless one written on a single piece (`I live on Ahornweg now`) is left as written and put to you in review, since sentences that only name a street look the same. A house's kind (`Cottage`, `Rectory`) stays in its stand-in, as a street's kind does. So does a building or a district name the address models leave outside the address, like a name before `Torre` or `Edificio`.
- Ages with no birth date in the same file stay as they are.

## Keyboard

| | |
|---|---|
| <kbd>⌘</kbd> <kbd>V</kbd> | Paste text to scrub |
| <kbd>⌘</kbd> <kbd>C</kbd> | Copy the selection, or the whole result |
| <kbd>⌘</kbd> <kbd>E</kbd> | Replace the selected value everywhere, keep the original of a selected stand-in or of the values selected in the Values panel, or take off your own mark |
| <kbd>↩</kbd> | Apply the kind and replacement in a value's editor |
| <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>L</kbd> | Show or hide the Values panel |
| <kbd>↑</kbd> <kbd>↓</kbd> | Move through the rows of the Values panel; with <kbd>⇧</kbd> select several, with <kbd>⌘</kbd> go to the first or last |
| <kbd>⌘</kbd> <kbd>Z</kbd> | Undo your last mark, edit, kept original or review choice |
| <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>Z</kbd> | Redo it |
| <kbd>⌘</kbd> <kbd>S</kbd> | Save the result |
| <kbd>esc</kbd> | Close a value's editor, cancel, or start over |

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

`Robustness` takes known generated cases and transforms them the ways real text arrives: a UTF-8 byte-order mark and UTF-16 XML, zero-width characters, soft hyphens and no-break spaces inside names, emails and numbers, all capitals and all lowercase, formatting that splits a word, reordered records, columns and keys, two people whose SSNs end alike, and personal data in links. It checks that nothing leaks, the output still parses, and a person's field and the note about them take one stand-in. Leaks are judged by an evaluator in `Tests/ScrubTestSupport` that uses only the generator's own truth, never Scrub's detectors: it looks for every part of a value (a name's words, an email's local part, a number's digits or its last four), not only the whole value. The property and payload tests use it too.

Real text is measured separately, and gates releases. `scripts/eval-gate.sh` runs `RealCorpus` over the human-labelled documents in `~/Work/scrub-eval-data` (or `SCRUB_EVAL_DATA`), and is skipped when they are absent. Per set it measures recall by label, the documents with any labelled value left, the share of other words changed, and the review burden (findings asked about per 1,000 words), and fails when one is worse than `Tests/ScrubCoreTests/RealCorpus/baseline.json` beyond a small tolerance. The baseline holds aggregate numbers only; the labelled text stays outside the repository and is never used for training or tuning. A fixed fifth of each set, chosen by a hash of each document's id, is a holdout that ordinary runs leave out; `scripts/eval-gate.sh --holdout` runs it alone and is for release checks only (`scripts/release.sh` runs both). `SCRUB_REAL_CORPUS_RECORD=1` records a new baseline after a deliberate change. The test file documents the format and its other switches.

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
