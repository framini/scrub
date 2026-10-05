"""The name model's tokenizer, features and network.

Sources/ScrubCore/NameModel.swift re-implements all of this; change both
together. Words are runs of letters, marks and digits joined by inner
connectors (. _ - ' ’ @), so "maria.gonzalez" and "Hye-jin" stay one word.
Each other non-space character is its own token, and so is each newline.
"""
import unicodedata

import torch
from torch import nn

BUCKETS = 1 << 15
EMBED = 48
HIDDEN = 64
KERNEL = 5
DILATIONS = (1, 2, 4)
SHAPES = 14
CONNECTORS = set(".-_'’@")


def is_word(ch):
    return unicodedata.category(ch)[0] in "LMN"


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


def lower(word):
    return "".join(ch.lower() for ch in word)


def buckets(word):
    """Hashed pieces of the lowercased word: the whole word and its 2-, 3- and
    4-grams. Each piece takes two rows, from the low and high bits of its hash,
    so two pieces that share one row rarely share both. The whole word's rows
    come first."""
    marked = "<" + lower(word) + ">"
    pieces = [marked]
    for size in (2, 3, 4):
        pieces += [marked[i:i + size] for i in range(len(marked) - size + 1)]
    rows = []
    for piece in pieces:
        h = fnv1a(piece.encode("utf-8"))
        rows += [h % BUCKETS, (h >> 16) % BUCKETS]
    return rows


def shape(word):
    letters = [ch for ch in word if unicodedata.category(ch)[0] == "L"]
    upper = [ch for ch in letters if ch.isupper()]
    return [
        float(bool(word) and word[0].isupper()),
        float(len(letters) > 1 and len(upper) == len(letters)),
        float(bool(letters) and not upper),
        float(any(unicodedata.category(ch) == "Nd" for ch in word)),
        float("." in word and len(word) > 1),
        float("_" in word),
        float("-" in word and len(word) > 1),
        float("@" in word and len(word) > 1),
        float(word == "\n"),
        float(len(word) == 1 and not is_word(word) and word != "\n"),
        min(len(word), 20) / 20,
        float(any(ord(ch) > 127 for ch in letters)),
        float(0 < len(upper) < len(letters) and any(ch.isupper() for ch in word[1:])),
        float("'" in word or "’" in word),
    ]


class NameModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.embed = nn.EmbeddingBag(BUCKETS, EMBED, mode="mean")
        self.project = nn.Linear(EMBED + SHAPES, HIDDEN)
        self.convs = nn.ModuleList(nn.Conv1d(HIDDEN, HIDDEN, KERNEL, dilation=d, padding=d * (KERNEL // 2)) for d in DILATIONS)
        self.out = nn.Linear(HIDDEN, 1)

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
        return self.out(h.transpose(1, 2)).squeeze(-1), mask
