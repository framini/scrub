# Name lists

`derive.py` writes `Sources/ScrubCore/Resources/NameLists.txt`, the lists Scrub
uses as supporting evidence for names (`Sources/ScrubCore/NameLists.swift`):

- `[first]`: first names the Social Security Administration counts for at
  least 2,000 people born from 1930 on.
- `[surname]`: surnames the 2010 Census counts for at least 1,000 people.
- `[wordlike]`: names from either list that are also ordinary English words
  ("rose", "will", "hunter"), plus months and weekdays. These count as names
  only where nothing else could stand: a greeting, a sign-off, after a title.
- `[ordinary]`: words the books write in lowercase at least 3 times and at
  least as often as capitalised inside a sentence, plus
  `../ContextModel/common-words.txt`.
- `[female]` and `[male]`: first names given to at least 200 people born
  from 1930 on, 95 in 100 of them girls, or boys ("siobhan", "mateus").
  Names given to either ("jordan", 75% boys) are in neither. Scrub keeps a
  title from joining a first name of the other sex ("Ms Okafor" and "Mateus
  Okafor" are two people) and gives such a name a stand-in of its sex.

Sources, licences and checksums are in the script and in `THIRD_PARTY_NOTICES.md`.

## Rebuilding

```sh
python3 derive.py            # downloads to .cache/ (git-ignored), writes the resource
shasum -a 256 ../../Sources/ScrubCore/Resources/NameLists.txt
```

Set the printed SHA-256 as `NameLists.checksum` in `NameLists.swift`; a file
that does not match is not loaded, and Scrub then runs without the lists. The
output is sorted, so the same sources always give the same bytes. Then run the
whole test suite, NameGaps and PIIGaps, and the payload properties.
