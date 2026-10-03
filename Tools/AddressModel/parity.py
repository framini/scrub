"""Writes the reference the Swift port is checked against: for each text, its
tokens (UTF-16 offsets), the model's three logits for each, and the addresses
it decodes.

    python parity.py --load AddressModel.bin.pt > ../../Tests/ScrubCoreTests/Fixtures/address-model-parity.json
"""
import argparse
import json
import random

import torch

from model import WIDE, AddressModel
from train import batch_tensors, decode, encode, quantized

TEXTS = [
    "Regards,\nOren Halloway\n2200 Kessler Avenue, Suite 410\nBoise, ID  83702\nPhone: (208) 555-0143",
    "Please send it to Flat 3, 27 Pellow Gardens, Bristol BS6 5QR — I moved last month.",
    "Lindenhofer Straße 48a\n70178 Stuttgart\nTel. +49 711 555 0144",
    "Return address:\nul. Wrzosowa 18/4\n02-791 Warszawa",
    "Via dei Tessitori 9, 50122 Firenze (FI)",
    "re: order 77120\nHi Saoirse,\n\nYour replacement card has shipped.",
    "v2.14.1 released on 12 March 2024; Python 3.12.11 (main, Aug 18 2025)",
    "Café crème, naïve résumé — é combining mark, İstanbul, ß, ǅ titlecase, 12º andar.",
    "emoji 👩🏽‍💻 at 4 Rookery Lane 🇸🇪 and tabs\tbetween\twords\r\nand CRLF lines 1015 GC",
    "Blk 418 Tampines Street 41 #09-221, Singapore 520418",
    "٣٤ شارع and １２３ full-width digits, 3-14-2 Ebisu-minami, Shibuya-ku",
    "\x1c\x1f  　 odd spaces​zero width 9",
    "",
    "   ",
    "\n\n\n",
    "Please send the keys to Flat B, The Old Rectory, Little Hadham by Friday.",
    "Unsere neue Adresse: Hauptstraße, Berlin-Mitte\nTel. 030 555 0199",
    "bitte schick das paket an lindenhofer straße 48a, 70178 stuttgart, danke!",
    "can you forward my post to 14 rookery lane, leeds ls6 2ab",
    "take the coast road for about 12 miles and turn left at the second roundabout",
]


def utf16(text, index):
    return len(text[:index].encode("utf-16-le")) // 2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", required=True)
    args = parser.parse_args()
    model = AddressModel()
    model.load_state_dict(torch.load(args.load, map_location="cpu"))
    model.eval()
    quantized(model)
    rng = random.Random(4)
    words = "Send it to 14 Mill Lane , Leeds LS6 2AB or Suite 400 in Boise , ID 83702 \n order 77120".split(" ")
    texts = TEXTS + [" ".join(rng.choice(words) for _ in range(6000))]
    cases = []
    with torch.no_grad():
        for text in texts:
            feats, labels, tokens = encode(text)
            logits, spans = [], []
            if feats:
                ids, offsets, shapes, lengths, _ = batch_tensors([(feats, labels)], "cpu")
                out, mask = model(ids, offsets, shapes, lengths)
                rows = out[mask]
                logits = [[round(v, 5) for v in row] for row in rows.tolist()]
                spans = decode(text, tokens, torch.softmax(rows, dim=-1).tolist(), numberless=WIDE)
            cases.append({"text": text, "tokens": [[utf16(text, s), utf16(text, e)] for s, e in tokens], "logits": logits,
                          "addresses": [[utf16(text, s), utf16(text, e)] for s, e in spans]})
    print(json.dumps(cases, ensure_ascii=False))


if __name__ == "__main__":
    main()
