"""Writes the references the Swift port is checked against.

    python parity.py --model checkpoint/ --valid valid.jsonl --prose prose.txt \
        --tokens ../../Tests/ScrubCoreTests/Fixtures/context-tokenizer-parity.json \
        --logits ../../Tests/ScrubCoreTests/Fixtures/context-model-parity.json

The tokenizer reference holds a few hundred strings (generated documents,
written edge cases and random runs of characters from many scripts) with
the pieces and UTF-16 offsets the tokenizer gives them. The model reference
holds windows of pieces with the logits of the network as the weight file
stores it: int8 embedding rows and an fp16 body, computed in float32.
"""
import argparse
import json
import random

import numpy as np
import torch
from transformers import AutoModelForTokenClassification, PreTrainedTokenizerFast

from export import stored

WRITTEN = [
    "Hello world", "„abc", "ﬁle ﬂow ﬀﬃ", "éte café", "a<s>b</s>c<pad>d<unk>e", "x 👩🏽‍💻 y 🇸🇪 ❤️", "Ａｂｃ　ｄｅ",
    "tab\there\r\nnew\rold", "▁odd▁mid ▁", "İstanbul ß ǅ ŉ", "王小明 called 김민준 and Ελένη Παπαδοπούλου", "a​b‌‍c⁠d",
    "\x1cx", "\x1c\x1fxy z", "\x00lead nul", "…½①②™©", "Zürich straße Łódź Gdańsk Tórshavn", "x  y", "  lead", "trail  ", "M&M's",
    "\xa0nbsp thin　ideo", "﻿bom start", "soft\xadhyphen", "rtl ‏mark‎ here", "ٱلْعَرَبِيَّة مرحبا بكم",
    "हिन्दी नमस्ते स्वागत", "ภาษาไทย ราคาพิเศษ", "한국어 화이팅 각", "日本語 確認 ｶﾀｶﾅ ﾊﾟﾋﾟ", "Ошибка сервера Ёлка", "שלום עולם",
    "user=k.osei action=login ts=2026-09-30T10:42:07Z", "def f(x):\n    return x**2  # 𝔣𝔞𝔫𝔠𝔶",
    "https://deploy:velvet-Cobalt-47@git.corvane.test/app.git", "@maria.gonzalez #billing <@U02ABC> ~/Users/kofi/notes.txt",
    "IBAN GB82 WEST 1234 5698 7654 32, card 4111-1111-1111-1111", "Ⅻ ⅻ ㎏ ㎡ ℃ ℉ ℡ № ℻", "ǈǋǲ ĳ Ĳ ŀ", "ｱｲｳｴｵ ｧ",
    "pneumonoultramicroscopicsilicovolcanoconiosis supercalifragilisticexpialidocious", "0123456789" * 8,
    "a" * 300, "𝐀𝐁𝐂 𝑥𝑦𝑧 𝟘𝟙𝟚", "Ꭰ Ꮳ ᏸ", "é̂̃ ȫ", "ﷺ ﷻ ﷽", "́lead mark", "‐‑‒–—―", "«»‹›“”‘’‚„",
    "", " ", "\n\n", "\t",
]
POOLS = {
    "latin": "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    "accents": "àáâãäåæçèéêëìíîïñòóôõöøùúûüýÿĀāĂăĄąĆćĈĉĊċČčĎďĐđŁłŃńŇňŐőŒœŘřŚśŠšŤťŮůŰűŸŹźŻżŽžșțẞßİıǅǈǋ",
    "marks": "̧̨̣̱̀́̂̃̈̊̌ͅ⃝",
    "cyrillic": "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯіїєґ",
    "greek": "αβγδεζηθικλμνξοπρστυφχψωάέήίόύώΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ",
    "cjk": "王小明東京資料確認高温注意牛乳寿司天谢的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年",
    "kana": "あいうえおかきくけこさしすせそたちつてとなにぬねのアイウエオカキクケコガギグゲゴパピプペポーッャュョ",
    "hangul": "가나다라마바사아자차카타파하설정화이팅김민준부산ᄀ까ᅢᆨᆩ",
    "arabic": "ابتثجحخدذرزسشصضطظعغفقكلمنهويءآأؤإئىةَُِّْ",
    "hebrew": "אבגדהוזחטיכלמנסעפצקרשתךםןףץ",
    "devanagari": "अआइईउऊएऐओऔकखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसह्ािीुूेैोौंः",
    "thai": "กขคฆงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮะัาำิีึืุู่้๊๋",
    "symbols": ".,;:!?'\"()[]{}<>@#$%^&*_-+=/\\|~`…–—•·°±×÷€£¥©®™§¶",
    "emoji": "😀😂🥲🤖👩👨🏽🏿‍💻🚀❤️🇸🇪🇯🇵🔥✨🎉",
    "spaces": " \t\n\r\xa0  ​　 ­﻿",
    "odd": "\x00\x01\x1b\x1c\x1f\x7f▁ﬁﬂ①②½™ＡａⅣ㎡",
}


def utf16(text, index):
    return len(text[:index].encode("utf-16-le")) // 2


def soup(rng):
    """A run of characters from a few scripts, with spaces between some."""
    pools = rng.sample(sorted(POOLS), rng.randint(1, 4))
    out = []
    for _ in range(rng.randint(1, 60)):
        out.append(rng.choice(POOLS[rng.choice(pools)]))
        if rng.random() < 0.2:
            out.append(" ")
    return "".join(out)


def tokenizer_cases(tok, valid, rng):
    texts = list(WRITTEN)
    texts += [json.loads(line)["text"] for line in open(valid).read().splitlines()[:180]]
    texts += [soup(rng) for _ in range(220)]
    cases = []
    for text in texts:
        enc = tok(text, add_special_tokens=False, return_offsets_mapping=True)
        cases.append({"text": text, "ids": enc["input_ids"],
                      "offsets": [[utf16(text, s), utf16(text, e)] for s, e in enc["offset_mapping"]]})
    return cases


def model_cases(model_dir, tok, valid, prose):
    """Windows as the stage reads them: whole 128-piece windows of prose and
    short ones of generated documents and non-Latin text."""
    tensors, _ = stored(model_dir)
    prefix = tensors["prefix"]
    model = AutoModelForTokenClassification.from_pretrained(model_dir).eval()
    state = model.state_dict()
    with torch.no_grad():
        state[prefix + "embeddings.word_embeddings.weight"].copy_(torch.from_numpy(tensors["word_rows"].astype(np.float32) * tensors["word_scale"][:, None]))
        for i, layer in enumerate(tensors["layers"]):
            p = f"{prefix}encoder.layer.{i}."
            q, k, v = np.split(layer["qkv"].astype(np.float32).T, 3)
            for name, value in (("attention.self.query.weight", q), ("attention.self.key.weight", k), ("attention.self.value.weight", v),
                                ("attention.output.dense.weight", layer["out"].astype(np.float32).T),
                                ("intermediate.dense.weight", layer["up"].astype(np.float32).T),
                                ("output.dense.weight", layer["down"].astype(np.float32).T)):
                state[p + name].copy_(torch.from_numpy(np.ascontiguousarray(value)))
    texts = [" ".join(open(prose).read().splitlines()[i * 40:(i + 1) * 40]) for i in range(6)]
    texts += [json.loads(line)["text"] for line in open(valid).read().splitlines()[200:206]]
    texts += ["王小明 called; 김민준 replied. Ελένη Παπαδοπούλου wrote back from Θεσσαλονίκη.",
              "Kofi works at Silverbrook Dental in Tamale, user k.mensah_77, passport no. X4471902."]
    cases = []
    with torch.no_grad():
        for text in texts:
            ids = tok(text, add_special_tokens=False)["input_ids"][:126]
            window = [tok.cls_token_id] + ids + [tok.sep_token_id]
            logits = model(input_ids=torch.tensor([window]), attention_mask=torch.ones(1, len(window), dtype=torch.long)).logits[0]
            cases.append({"ids": window, "logits": [round(float(x), 4) for x in logits.flatten()]})
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--valid", required=True)
    parser.add_argument("--prose", required=True)
    parser.add_argument("--tokens", required=True)
    parser.add_argument("--logits", required=True)
    args = parser.parse_args()
    tok = PreTrainedTokenizerFast.from_pretrained(args.model)
    json.dump(tokenizer_cases(tok, args.valid, random.Random(5)), open(args.tokens, "w"), ensure_ascii=False)
    json.dump(model_cases(args.model, tok, args.valid, args.prose), open(args.logits, "w"))


if __name__ == "__main__":
    main()
