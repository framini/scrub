"""Paragraphs from this Mac's man pages (options, synopses, prose with numbers), deduped against the evaluation sets.
    python tools/extract_man.py > data/man.txt   (paragraphs separated by a blank line)"""
import os, random, re, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from eval_lines import eval_grams, grams, norm

held = eval_grams()
ADDRESSY = re.compile(r"\b\d{1,5}\s+[A-Z][\w.]*(?:\s+[A-Z][\w.]*){0,3}\s+(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Boulevard|Blvd|Drive|Lane|Way|Place)\b|\b[A-Z]{2}\s+\d{5}(?:-\d{4})?\b|Suite \d|\bP\.?\s?O\.? Box\b|\b[A-Z]-\d{4,5}\s+[A-Z]")
pages = []
for section in ("man1", "man3", "man4", "man5", "man7", "man8"):
    folder = "/usr/share/man/" + section
    if os.path.isdir(folder):
        pages += sorted(os.path.join(folder, f) for f in os.listdir(folder))
random.Random(3).shuffle(pages)
out, dropped = [], 0
for path in pages[:2500]:
    try:
        raw = subprocess.run(["mandoc", "-T", "utf8", path], capture_output=True, timeout=10).stdout.decode("utf-8", "ignore")
    except (OSError, subprocess.TimeoutExpired):
        continue
    raw = re.sub(r".\x08", "", raw)
    for para in re.split(r"\n\s*\n", raw):
        lines = [l.strip() for l in para.splitlines() if l.strip()]
        if not lines or len(lines) > 12:
            continue
        if grams("\n".join(lines)) & held:
            dropped += 1
            continue
        text = "\n".join(lines)
        # Authors' postal addresses are addresses: left out, so negatives hold none.
        if ADDRESSY.search(text) or re.match(r"(?i)authors?\b", text):
            continue
        if 20 <= len(text) <= 700 and "@" not in text:
            out.append(text)
random.Random(4).shuffle(out)
print(f"paragraphs={len(out)} dropped={dropped}", file=sys.stderr)
print("\n\n".join(out))
