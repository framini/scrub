"""Writes Sources/ScrubCore/Resources/NameLists.txt: the first names and
surnames Scrub may use as supporting evidence that a capitalised word is a
name, which of them are also ordinary English words, and the ordinary words
themselves.

    python3 derive.py [--cache DIR] [--out PATH]

Sources, each checked against the SHA-256 below before it is read:

- First names, and which are clearly a woman's or a man's: the Social
  Security Administration's national baby-name file (names.zip, one file a
  year of births, counted by sex), a work of the U.S. Government.
- Surnames: the Census Bureau's 2010 surname file (names.zip,
  Names_2010Census.csv), a work of the U.S. Government.
- Ordinary words: how often each word is written in lowercase, rather than
  capitalised inside a sentence, across 49 public-domain books from Project
  Gutenberg, plus Tools/ContextModel/common-words.txt.

Both government sites refuse scripted downloads from some networks. The
script then fetches the same file from the Internet Archive's copy of that
exact URL; the checksum guarantees it is the same file either way.

Nothing here runs at build time or in Scrub: Scrub ships only the text file
this writes. Python 3.12 standard library only.
"""
import argparse
import collections
import csv
import hashlib
import io
import os
import re
import sys
import urllib.request
import zipfile

# Says who is asking, so a source's owner can tell these fetches apart.
USER_AGENT = "scrub-tools/1.0"
SSA = ("https://www.ssa.gov/oact/babynames/names.zip", "20260928194647",
       "cd78e975ed7bb358e018dd62fbe14ced89295e9581c49172ca4eedcb011b3724")
CENSUS = ("https://www2.census.gov/topics/genealogy/2010surnames/names.zip", "20260909180332",
          "117c41cb4668727b7627b2845b6df3f83eb2a22a1813f42c0ff4bdcab86de135")
BOOKS = [
    (11, "01b38ea4c710a84bc18d0bd41271a5a1a92b94e97b2812f4dece97d4a694725e"),
    (35, "2892e919000e17c83e1dac51b30f4675db50536b644d7579fe8a89bb399a9bdc"),
    (36, "8417469e3ab664749f7b36ebb85799075818207b0380b54c27d07d592a44117d"),
    (41, "6847c02f49c9ff8a5e2a0e8f49842bf3bffc7f5a87216c895a6b64f26ecf9353"),
    (43, "b43448a88391591f9cf82b25553df00faf47a2752a873185fcdd1156eebdb990"),
    (46, "8c36b93723d454982df045ec0efdf2664e5a48e6b5e2f670e883575f75ad0cc8"),
    (74, "74d77384b123a6360db9ab58463cff8b38df8525fbdc6000c81ee388e1f3cf10"),
    (76, "d617a37aa7ae1e1a93dcde2634db2bccb86824e31e29a55230bdbf77d6872d59"),
    (84, "7810cd483cffcf2cc8a1d8f0d5807931e69d4f48cd14149b8c76f88af82fead3"),
    (98, "d54c2b80d40a40b982cd88852c6180bb944d95acdb028af3d0e01a1750681784"),
    (113, "6b0bb5fbd0c4e873d2d22028da9d753cf3977d5f70ac58221556b28060badbf5"),
    (120, "5bc08275eacea8640b1aa185c645283bb8c564d7b23df6b03437d229b4fc6ebd"),
    (135, "6cf3b9d6fc5e6f733737425267d3af296d7f99f9b9fd1d255a3ab7689a6346ab"),
    (145, "dc2e0107e6ae07e8e33da934b2ec4e8e600826a2e0cd48df265119cd02e5fb50"),
    (158, "532b122b4e6a76cc556d6fdcd729b5892f5c4ce4a1b7060b9f832adfad8680dc"),
    (161, "22272ec4d4da2f50cda51edf34ab8486b325c4a99580120db565fb8917228a22"),
    (174, "38f36b510417177aa87a6a24c968e3ec63a447b7df36a9c1a7c5a3f2d9e51547"),
    (205, "2d9a76a2e3e8195c69430516ebd33c4d0757a53ad432ff6186b7b794e6fe99f9"),
    (219, "c0b0bc91c7695f9d01aacb240e82a9b559f57558f98ad0b1f167eba21f6be6f7"),
    (345, "96cd16eacdbfebae8fdda5591f66e0cc8ee76be18e0cd1aca02bc00615782d28"),
    (514, "677d034b4a3d1cea92d075939878f852a7a3ec757dc9ed05ef0c40cab5c1e6de"),
    (600, "6ce7d6ff7288263f1fd07d7ecfc07e419735cbbb4dff5107964af1afd8b2079e"),
    (768, "e533fe750589f0421d5d744576315f5c2b9b0d69e981179ea0551bbf134c5e02"),
    (815, "734b3b0352dc2ec312a6b2b9e9165aac054439eee2d6e8d83d1fd9a35d1c9e2d"),
    (829, "fca36de3de0d8b831b7588cf1df84639ccf4c503172d6444ee61d1c1b2036edd"),
    (1184, "64f8d5cfa51fcecb904abf7312d395d512a71817e7359b91288beb50517c3836"),
    (1232, "33496a305f7a4b933784fb5aec95f920fbc3d4687794817e4cc444aa6578d2e4"),
    (1260, "13414dee2951c3ee731d76d2ffd822016b2479c892162760c5d0eb2aa5fa7631"),
    (1342, "3f6bb9d6f78e0293b56acd4714dd68cb7d6d1d293402031ce9d5a216bcaf9d75"),
    (1400, "9a637118af8e953e9764ec603d9b0a032883384d465acac2e27966a80cf1c6f8"),
    (1661, "922e2a12ccb43a4c9544c260b2166c6ad2097aeb5957faeee113f173bb857cd0"),
    (1727, "ffbdb29c3dda284b65c11243db1a98167826a70c81bca2ed4b6232f86c905fb9"),
    (1952, "20c7788eeae2fe3a0efd51a1f08b6723366a4be0778d65db219149a3522651d4"),
    (1998, "0854ebabe235d46c8e5e099418c5189b1df0848898c552009b70d924b9065d05"),
    (2554, "d139120965c81f10e3f747d891a49babdb49d986b25f7ab25299b1bbf4731146"),
    (2591, "377ebb8ca06cd8bc0b1015ddb54766c44f50dece731c53bb030f1cc00f54092a"),
    (2600, "2d5bb2ad5f422765e714617e21fa31bbaf8958aa79682c86fca6660fcc5d1b2b"),
    (2641, "3dce58eb1786b10b79f8688968d293a1990dfed4a1f83a5c04a6a2a10381db36"),
    (2701, "907420db6c4b68c70e2988cd2ad9c8cf79138667a01b63376d18dd17fef1a18b"),
    (2814, "6be7d8400ac2549459307d1c1a20a25c86a736984269d3e9d989c817814be60c"),
    (3207, "3de1e492641d939567a8b0de827fb13e1ad992324f9ac8b204f60475009b7294"),
    (3600, "1b4c87312f0890e04cecee48e3a5fa263de65743230b819e16cb1bd72f7aee59"),
    (4085, "048e86bf69c08655ff92423c7b7d04c8110481521bf901acda0df932aa53b17c"),
    (4300, "e03094626f9528cf3fc287a49d6edbdbf47cd40483cb13ceb301e74e15ebbf9e"),
    (5200, "0933283a19a4daaef0d412e8f69c74fae126b0a946cb74b8f3c783a8e869830d"),
    (6130, "ca4f23115b384b0219427ef208e875f0351820b8f80f28259272997ea581c36b"),
    (16328, "8909085dc48daf123d29c40ecbb3837b16ba7f96bf0cbb9fe72de133a2d35348"),
    (25344, "82836a0a74a55163187b1d62e0ee6e6500a9ae2714711dcef28f66780ce5650c"),
    (28054, "2e75c187cb750df3f7c910fa90970b264b9a4fee212be2a73c6bb507d9ad22fe"),
]

# A first name given to at least this many people born since 1930, and a
# surname held by at least this many people in 2010. Rarer names add more
# words that collide with ordinary ones than names worth knowing.
FIRST_MIN = 2000
FIRST_SINCE = 1930
SURNAME_MIN = 1000
# A first name is clearly a woman's or a man's when at least this many people
# born since 1930 were given it and at least this share of them were of one
# sex: "Mateus" (994 boys, no girls) is a man's, "Jordan" (75% boys) is either.
GENDER_MIN = 200
GENDER_SHARE = 0.95
# A word is ordinary when the books write it in lowercase at least this often,
# and at least as often in lowercase as capitalised inside a sentence: "rose",
# "will", "hunter", but not "emma", "frank" or "dean".
ORDINARY_MIN = 3
ORDINARY_SHARE = 0.5
# Dates are written with capitals but name no one.
CALENDAR = ("january february march april may june july august september october november december "
            "monday tuesday wednesday thursday friday saturday sunday").split()


def fetch(url, digest, cache, snapshot=None):
    path = os.path.join(cache, hashlib.sha256(url.encode()).hexdigest()[:16] + "-" + url.rsplit("/", 1)[-1])
    if not os.path.exists(path):
        sources = [url] + ([f"https://web.archive.org/web/{snapshot}id_/{url}"] if snapshot else [])
        for source in sources:
            try:
                request = urllib.request.Request(source, headers={"User-Agent": USER_AGENT})
                data = urllib.request.urlopen(request, timeout=120).read()
            except OSError as error:
                print(f"{source}: {error}", file=sys.stderr)
                continue
            if hashlib.sha256(data).hexdigest() == digest:
                with open(path, "wb") as out:
                    out.write(data)
                break
            print(f"{source}: checksum differs", file=sys.stderr)
        else:
            sys.exit(f"could not fetch {url} with SHA-256 {digest}")
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != digest:
        sys.exit(f"{path}: checksum differs")
    return data


def first_names(archive):
    """The first names, and those clearly given to girls and to boys."""
    counts, girls = collections.Counter(), collections.Counter()
    with zipfile.ZipFile(io.BytesIO(archive)) as names:
        for member in names.namelist():
            match = re.fullmatch(r"yob(\d{4})\.txt", member)
            if not match or int(match.group(1)) < FIRST_SINCE:
                continue
            for line in names.read(member).decode("ascii").splitlines():
                name, sex, count = line.split(",")
                counts[name.lower()] += int(count)
                if sex == "F":
                    girls[name.lower()] += int(count)
    first = {name for name, count in counts.items() if count >= FIRST_MIN}
    known = {name: count for name, count in counts.items() if count >= GENDER_MIN}
    female = {name for name, count in known.items() if girls[name] / count >= GENDER_SHARE}
    male = {name for name, count in known.items() if (count - girls[name]) / count >= GENDER_SHARE}
    return first, female, male


def surnames(archive):
    with zipfile.ZipFile(io.BytesIO(archive)) as names:
        rows = csv.DictReader(io.StringIO(names.read("Names_2010Census.csv").decode("ascii")))
        # "ALL OTHER NAMES" totals the rest; it is no surname.
        return {row["name"].lower() for row in rows if row["name"].isalpha() and int(row["count"]) >= SURNAME_MIN}


WORD = re.compile(r"[A-Za-z]+(?:['’][a-z]+)?|[.!?:;\"“”‘(\[]")


def word_cases(books):
    """For each word: how often it is written in lowercase, and how often
    capitalised where no sentence starts."""
    lower, capital = collections.Counter(), collections.Counter()
    for text in books:
        start, end = text.find("*** START OF"), text.find("*** END OF")
        if start >= 0 and end > start:
            text = text[text.find("\n", start) + 1:end]
        opening = True
        for match in WORD.finditer(text):
            token = match.group(0)
            if not token[0].isalpha():
                opening = token != ";"
                continue
            if token.islower():
                lower[token] += 1
            elif token[0].isupper() and token[1:].islower() and not opening:
                capital[token.lower()] += 1
            opening = False
    return lower, capital


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", default=os.path.join(here, ".cache"))
    parser.add_argument("--out", default=os.path.join(here, "../../Sources/ScrubCore/Resources/NameLists.txt"))
    args = parser.parse_args()
    os.makedirs(args.cache, exist_ok=True)

    first, female, male = first_names(fetch(SSA[0], SSA[2], args.cache, SSA[1]))
    last = surnames(fetch(CENSUS[0], CENSUS[2], args.cache, CENSUS[1]))
    books = [fetch(f"https://www.gutenberg.org/cache/epub/{number}/pg{number}.txt", digest, args.cache).decode("utf-8", "ignore")
             for number, digest in BOOKS]
    lower, capital = word_cases(books)
    common = {line.strip() for line in open(os.path.join(here, "../ContextModel/common-words.txt")) if line.strip()}
    ordinary = {word for word, count in lower.items()
                if count >= ORDINARY_MIN and count / (count + capital[word]) >= ORDINARY_SHARE and "'" not in word and "’" not in word}
    ordinary |= {word for word in common if word.isalpha()}
    wordlike = ((first | last) & ordinary) | set(CALENDAR)

    with open(args.out, "w", encoding="utf-8", newline="\n") as out:
        out.write("# Scrub's name lists, written by Tools/NameLists/derive.py. Sources and licences: THIRD_PARTY_NOTICES.md.\n")
        for section, words in (("first", first), ("surname", last), ("wordlike", wordlike), ("ordinary", ordinary), ("female", female), ("male", male)):
            out.write(f"[{section}]\n")
            out.write("".join(word + "\n" for word in sorted(words)))
    print(f"first {len(first)}, surname {len(last)}, wordlike {len(wordlike)}, ordinary {len(ordinary)}, female {len(female)}, male {len(male)}", file=sys.stderr)


if __name__ == "__main__":
    main()
