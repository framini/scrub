"""The address model's tokenizer, features and network.

Sources/ScrubCore/AddressModel.swift re-implements all of this; change both
together. Words are runs of letters, marks and digits joined by inner
connectors (. _ - ' ’ @), as in the name model, so "B3J", "1100-053" and
"St." stay one word. Each other non-space character is its own token, and so
is each newline. A token is labelled O, B (first of an address) or I.
"""
import os
import unicodedata

import torch
from torch import nn

BUCKETS = 1 << 15
EMBED = 48
HIDDEN = 64
KERNEL = 5
DILATIONS = (1, 2, 4, 8)
# The token's 15 shape flags and 3 of its line's (see line_shapes). The wide
# model (ADDRESS_WIDE=1 in the environment) reads a fourth: whether the line
# holds a capital letter.
WIDE = os.environ.get("ADDRESS_WIDE", "0") == "1"
SHAPES = 19 if WIDE else 18
LABELS = 3  # O, B, I
CONNECTORS = set(".-_'’@")


def is_word(ch):
    return unicodedata.category(ch)[0] in "LMN"


def is_digit(ch):
    return unicodedata.category(ch) == "Nd"


def is_letter(ch):
    return unicodedata.category(ch)[0] == "L"


def tokenize(text):
    """[(start, end)] in code points."""
    tokens, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if is_word(ch):
            j = i + 1
            while j < n and (is_word(text[j]) or (text[j] in CONNECTORS and j + 1 < n and is_word(text[j + 1]))):
                j += 1
            tokens.append((i, j))
            i = j
        elif ch == "\n" or not ch.isspace():
            tokens.append((i, i + 1))
            i += 1
        else:
            i += 1
    return tokens


def fnv1a(data):
    h = 0x811C9DC5
    for byte in data:
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    return h


def folded(word):
    """Lowercase, with every decimal digit read as 0: a postcode or house
    number is known by its shape, not its value."""
    return "".join("0" if is_digit(ch) else ch.lower() for ch in word)


def buckets(word):
    """Hashed pieces of the folded word: the whole word and its 2-, 3- and
    4-grams, each taking two rows (the low and high bits of its hash)."""
    marked = "<" + folded(word) + ">"
    pieces = [marked]
    for size in (2, 3, 4):
        pieces += [marked[i:i + size] for i in range(len(marked) - size + 1)]
    rows = []
    for piece in pieces:
        h = fnv1a(piece.encode("utf-8"))
        rows += [h % BUCKETS, (h >> 16) % BUCKETS]
    return rows


def shape(word):
    letters = [ch for ch in word if is_letter(ch)]
    upper = [ch for ch in letters if ch.isupper()]
    count = sum(1 for ch in word if is_digit(ch))
    return [
        float(bool(word) and word[0].isupper()),
        float(len(letters) > 1 and len(upper) == len(letters)),
        float(bool(letters) and not upper),
        float(count > 0),
        float(count > 0 and count == len(word)),
        float(1 <= count <= 2),
        float(count == 3),
        float(count == 4),
        float(count == 5),
        float(count >= 6),
        float(count > 0 and bool(letters)),
        float(word == "\n"),
        float(len(word) == 1 and not is_word(word) and word != "\n"),
        min(len(word), 20) / 20,
        float(any(ord(ch) > 127 for ch in letters)),
    ]


def line_shapes(text, tokens):
    """Per token: first on its line, its line holds a digit, its line holds a
    comma, and (for the wide model) its line holds a capital letter: in text
    written all in lowercase, a lowercase word tells nothing."""
    result, line, start = [], [], 0
    lines = []
    for index, (s, e) in enumerate(tokens):
        line.append(index)
        if text[s:e] == "\n":
            lines.append(line)
            line = []
    if line:
        lines.append(line)
    flags = [None] * len(tokens)
    for line in lines:
        words = [i for i in line if text[tokens[i][0]:tokens[i][1]] != "\n"]
        digit = float(any(any(is_digit(ch) for ch in text[tokens[i][0]:tokens[i][1]]) for i in words))
        comma = float(any(text[tokens[i][0]:tokens[i][1]] == "," for i in words))
        capital = float(any(any(ch.isupper() for ch in text[tokens[i][0]:tokens[i][1]]) for i in words))
        for position, i in enumerate(line):
            flags[i] = [float(position == 0 and text[tokens[i][0]:tokens[i][1]] != "\n"), digit, comma] + ([capital] if WIDE else [])
    return flags


class AddressModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.embed = nn.EmbeddingBag(BUCKETS, EMBED, mode="mean")
        self.project = nn.Linear(EMBED + SHAPES, HIDDEN)
        self.convs = nn.ModuleList(nn.Conv1d(HIDDEN, HIDDEN, KERNEL, dilation=d, padding=d * (KERNEL // 2)) for d in DILATIONS)
        self.out = nn.Linear(HIDDEN, LABELS)

    def forward(self, ids, offsets, shapes, lengths):
        """ids/offsets: flat bags for every token in the batch; shapes: [tokens, SHAPES]; lengths: tokens per document."""
        tokens = torch.cat([self.embed(ids, offsets), shapes], dim=1)
        x = torch.relu(self.project(tokens))
        width = int(lengths.max())
        batch = x.new_zeros(len(lengths), width, HIDDEN)
        mask = torch.arange(width, device=x.device)[None, :] < lengths[:, None]
        batch[mask] = x
        h = batch.transpose(1, 2)
        m = mask[:, None, :].float()
        for conv in self.convs:
            h = (h + torch.relu(conv(h))) * m
        return self.out(h.transpose(1, 2)), mask
