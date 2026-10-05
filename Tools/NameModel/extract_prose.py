"""Collects plain English sentences with no people in them from this Mac's
man pages, so the model sees ordinary prose and learns that an unfamiliar
word is not a name by default.

    python extract_prose.py > prose.txt
"""
import os
import random
import re
import subprocess
from pathlib import Path

from generate import FIRST, LAST

SKIP = re.compile(r"^(AUTHORS?|HISTORY|SEE ALSO|COPYRIGHT|BUGS|REPORTING BUGS|STANDARDS|ACKNOWLEDGEMENTS?|CREDITS|MAINTAINERS?|LICENSE)\b")


def known_names():
    names = {w.lower() for w in FIRST + LAST}
    source = Path(__file__).resolve().parents[2] / "Sources/ScrubCore/Names.swift"
    for table in re.findall(r'static let (?:first|last): \[String\] = """(.*?)"""', source.read_text(), re.S):
        names.update(w.lower() for w in table.split())
    return names


def main():
    pages = []
    for section in ("man1", "man3", "man5", "man8"):
        folder = "/usr/share/man/" + section
        if os.path.isdir(folder):
            pages += sorted(os.path.join(folder, f) for f in os.listdir(folder))
    random.Random(1).shuffle(pages)
    names = known_names()
    found = set()
    for path in pages[:1500]:
        try:
            raw = subprocess.run(["mandoc", "-T", "utf8", path], capture_output=True, timeout=10).stdout.decode("utf-8", "ignore")
        except (OSError, subprocess.TimeoutExpired):
            continue
        section, lines = None, []
        for line in re.sub(r".\x08", "", raw).splitlines():
            if line and not line.startswith(" "):
                section = line.strip()
            elif section and not SKIP.match(section):
                lines.append(line.strip())
        for sentence in re.split(r"(?<=[.!?])\s+", " ".join(lines)):
            sentence = re.sub(r"\s+", " ", sentence).strip()
            words = re.findall(r"[^\W\d_]+", sentence)
            if not (30 <= len(sentence) <= 200 and sentence[0].isupper() and sentence.endswith(".")):
                continue
            if sum(c.isalpha() for c in sentence) < 0.7 * len(sentence) or "@" in sentence:
                continue
            # Names can be ordinary words ("will", "mark"), so only a capitalised one past the first word rules a sentence out.
            if any(w.lower() in names and w[0].isupper() for w in words[1:]):
                continue
            found.add(sentence)
    print("\n".join(sorted(found)))


if __name__ == "__main__":
    main()
