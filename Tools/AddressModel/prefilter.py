"""The address model's line prefilter, mirrored from AddressModel.swift.

A line is read (with the two lines either side) when it holds a decimal digit
and a word of two letters, as before, or, with no digit, when it holds a cue
only an address line has: a word ending in a compound street kind
("Hauptstraße", "Kerkstraat", "Storgatan"), a foreign kind of street that
opens a street's name ("rue de la Paix", "via Roma", "calle Mayor"), a
capitalised kind of street or building after a capitalised word ("Mill Lane",
"The Old Rectory"), or a unit with a letter ("Flat B").
"""
import re
import unicodedata

SUFFIXES = ("straße", "strasse", "gasse", "platz", "allee", "ufer", "damm", "steig", "pfad", "straat", "laan", "gracht", "plein", "kade", "singel",
            "dijk", "steeg", "gatan", "vägen", "gränd", "torget", "gade", "gaden", "vej", "vejen", "stræde", "torvet", "veien", "vegen", "gata", "katu", "kuja", "polku", "weg")
# Words ending so that are no street: "brigade", "renegade", "arcade".
NOT_SUFFIXED = {"brigade", "brigades", "renegade", "renegades", "escapade", "promenade"}
# Kinds of street that open its name, in any case; the English-looking ones only before a capitalised word.
LEAD_KINDS = {"rue", "allée", "impasse", "chemin", "quai", "viale", "piazza", "piazzale", "vicolo", "strada", "calle", "avenida", "paseo", "rua",
              "travessa", "praça", "estrada", "alameda", "ulica", "aleja", "carrer", "chaussée", "rambla", "largo", "corso", "camino", "ronda", "via",
              "avenue", "boulevard", "plaza", "place", "route"}
LEAD_CAPITAL = {"via", "avenue", "boulevard", "plaza", "place", "route", "largo", "corso", "camino", "ronda"}
KINDS = {"street", "road", "lane", "avenue", "drive", "close", "crescent", "way", "place", "terrace", "court", "highway", "square", "gardens", "grove",
         "mews", "rise", "walk", "parade", "quay", "row", "hill", "view", "green", "vale", "chase", "wharf", "boulevard", "circle", "trail", "parkway",
         "esplanade", "yard", "path", "alley", "house", "cottage", "lodge", "farm", "barn", "manor", "rectory", "vicarage", "granary", "forge", "mill",
         "hall", "mansions", "tower", "building", "estate", "park"}
UNITS = {"flat", "apt", "apartment", "unit", "suite", "appt", "bâtiment", "escalier", "piso", "wohnung", "top"}


def words(line):
    """Runs of letters, an apostrophe inside one kept, with their offsets (as AddressModel.swift reads them)."""
    found, i, n = [], 0, len(line)
    while i < n:
        if line[i].isalpha():
            j = i + 1
            while j < n and (line[j].isalpha() or (line[j] in "'’" and j + 1 < n and line[j + 1].isalpha())):
                j += 1
            found.append((line[i:j], i, j))
            i = j
        else:
            i += 1
    return found


def has_digit(line):
    return any(unicodedata.category(ch) == "Nd" for ch in line)


def old_candidate(line):
    """Scrub's prefilter before: a decimal digit and a run of two letters."""
    return has_digit(line) and re.search(r"[^\W\d_]{2}", line) is not None


def cue(line):
    """A numberless line's cue (see the module's comment). Pairs of words count
    only when spaces alone part them."""
    found = words(line)
    for index, (word, start, end) in enumerate(found):
        lower = word.lower()
        if lower not in NOT_SUFFIXED and any(lower.endswith(s) and len(lower) > len(s) + 2 for s in SUFFIXES):
            return True
        joined = index + 1 < len(found) and line[end:found[index + 1][1]].isspace()
        nxt = found[index + 1][0] if joined else None
        if lower in LEAD_KINDS and nxt and (lower not in LEAD_CAPITAL or nxt[0].isupper()):
            return True
        if lower in KINDS and word[0].isupper() and index > 0 and line[found[index - 1][2]:start].isspace() and found[index - 1][0][0].isupper():
            return True
        if lower in UNITS and nxt is not None and len(nxt) == 1 and nxt.isupper():
            return True
    return False


def candidate(line, numberless=True):
    if old_candidate(line):
        return True
    return numberless and not has_digit(line) and cue(line)


def windows(text, numberless=True):
    lines, start = [], 0
    for match in re.finditer(r"[^\n]*\n|[^\n]+$", text):
        lines.append((match.start(), match.end(), candidate(match.group(0), numberless)))
    result = []
    for index, (s, e, c) in enumerate(lines):
        if not c:
            continue
        a, b = lines[max(0, index - 2)][0], lines[min(len(lines) - 1, index + 2)][1]
        if result and result[-1][1] >= a:
            result[-1] = (result[-1][0], max(result[-1][1], b))
        else:
            result.append((a, b))
    return result
