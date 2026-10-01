"""Writes the reference the Swift port is checked against: for each text,
its tokens (UTF-16 offsets) and the model's score for each.

    python parity.py --load NameModel.bin.pt > ../../Tests/ScrubCoreTests/Fixtures/name-model-parity.json
"""
import argparse
import json
import random

import torch

from model import NameModel
from train import batch_tensors, encode, quantize

TEXTS = [
    "Hi Arjun,\n\nYour replacement card has shipped.\n\nThanks,\nTariq",
    "spoke w lucia earlier, she says the card was charged twice",
    "ping @maria.gonzalez in #billing — Priya's laptop is missing",
    "Łukasz Wójcik and Ólafur Sigurðsson met Nguyễn Thị Lan in Zürich.",
    "Pieter van der Berg asked Ana María de la Cruz about it.",
    "王小明 called; 김민준 replied. Ελένη Παπαδοπούλου wrote back.",
    "The Jenkins build failed. Ask Alexa. Morgan Stanley wired it.",
    "Café crème, naïve résumé, coöperate — é combining mark, İstanbul, ß, ǅ titlecase.",
    "emoji 👩🏽‍💻 next to Sven 🇸🇪 and tabs\tbetween\twords\r\nand CRLF lines",
    "TODO(sven): drop it\n2026-09-30T10:42:07Z INFO user=k.osei action=login",
    "O'Brien, D'Angelo and Hye-jin x-y _under_ a.b. trailing- -leading",
    "\x1c\x1f  　 odd spaces​zero width",
    "",
    "   ",
]


def utf16(text, index):
    return len(text[:index].encode("utf-16-le")) // 2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", required=True)
    args = parser.parse_args()
    model = NameModel()
    model.load_state_dict(torch.load(args.load, map_location="cpu"))
    model.eval()
    with torch.no_grad():
        rows, scales = quantize(model.embed.weight)
        model.embed.weight.copy_(rows.float() * scales[:, None])
    rng = random.Random(4)
    words = "Maria said the refund for Okafor was approved by tomasz.w after Beatriz called\n".split(" ")
    texts = TEXTS + [" ".join(rng.choice(words) for _ in range(6000))]
    cases = []
    with torch.no_grad():
        for text in texts:
            feats, labels, tokens = encode(text)
            logits = []
            if feats:
                ids, offsets, shapes, lengths, _ = batch_tensors([(feats, labels)], "cpu")
                out, mask = model(ids, offsets, shapes, lengths)
                logits = [round(v, 5) for v in out[mask].tolist()]
            cases.append({"text": text, "tokens": [[utf16(text, s), utf16(text, e)] for s, e in tokens], "logits": logits})
    print(json.dumps(cases, ensure_ascii=False))


if __name__ == "__main__":
    main()
