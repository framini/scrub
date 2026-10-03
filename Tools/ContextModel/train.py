"""Fine-tunes a base encoder as the context model's token tagger.

    python train.py --base small --tokenizer pruned/ --train gen-train.jsonl real-train.jsonl \
        --valid gen-valid.jsonl real-valid.jsonl --out checkpoint/

`--base small` is Multilingual-MiniLM-L12-H384 (12 layers, 384 wide); `--base
base` is XLM-RoBERTa base (12 layers, 768 wide). Both use the XLM-R
vocabulary, so one pruned tokenizer serves both. Each document becomes windows
of 128 pieces (126 between the start and end markers, each window 96 pieces on
from the last), labelled B/I per class from its spans. Batches hold windows of
similar length. The shipped models used the defaults below and the learning
rate in the README.
"""
import argparse
import json
import math
import os
import random
import time

import torch
from transformers import AutoModelForTokenClassification, PreTrainedTokenizerFast

from export import LABELS

# The base encoders, at the revisions the shipped models were built from. Both MIT.
BASES = {
    "small": ("microsoft/Multilingual-MiniLM-L12-H384", "6e8c1ec6b4ec4e3fc6eb7d2cd834fcd582b61daf"),
    "base": ("FacebookAI/xlm-roberta-base", "e73636d4f797dec63c3081bb6ed5c7b0bb3f2089"),
}
L2I = {label: i for i, label in enumerate(LABELS)}
WINDOW, STRIDE = 128, 96


def load_tokenizer(pruned):
    return PreTrainedTokenizerFast(tokenizer_file=os.path.join(pruned, "tokenizer.json"), bos_token="<s>", eos_token="</s>",
                                   unk_token="<unk>", pad_token="<pad>", cls_token="<s>", sep_token="</s>")


def load_base(pruned, base):
    """The base encoder with a fresh classifier, its embeddings cut to the pruned pieces."""
    name, revision = BASES[base]
    model = AutoModelForTokenClassification.from_pretrained(name, revision=revision, num_labels=len(LABELS))
    old = torch.tensor(json.load(open(os.path.join(pruned, "old_ids.json"))))
    embeddings = model.get_input_embeddings()
    pruned_embeddings = torch.nn.Embedding(len(old), embeddings.weight.shape[1], padding_idx=1)
    pruned_embeddings.weight.data = embeddings.weight.data[old].clone()
    model.set_input_embeddings(pruned_embeddings)
    model.config.vocab_size = len(old)
    model.config.pad_token_id = 1
    return model


def windows(tok, text):
    """Token windows over `text`: (start, ids, offsets), without the markers."""
    enc = tok(text, add_special_tokens=False, return_offsets_mapping=True)
    ids, offs = enc["input_ids"], enc["offset_mapping"]
    inner = WINDOW - 2
    out, start = [], 0
    while True:
        out.append((start, ids[start:start + inner], offs[start:start + inner]))
        if start + inner >= len(ids):
            break
        start += STRIDE
    return out


def labels_for(offs, spans):
    """BIO per token from character spans; a token belongs to the span holding its first character."""
    out = []
    for s, e in offs:
        label = "O"
        if e > s:
            for a, b, c in spans:
                if a <= s < b or (s < a < e):
                    label = ("B-" if s <= a else "I-") + c
                    break
        out.append(L2I[label])
    return out


def make_examples(tok, paths, limit=None):
    examples = []
    for path in paths:
        for n, line in enumerate(open(path)):
            if limit and n >= limit:
                break
            d = json.loads(line)
            for _, ids, offs in windows(tok, d["text"]):
                examples.append(([tok.cls_token_id] + ids + [tok.sep_token_id], [-100] + labels_for(offs, d["spans"]) + [-100]))
    return examples


def batches(examples, size, pad, shuffle, rng):
    """Batches of `size`; when shuffling, windows of like length go together
    (sorted within runs of 50 batches) and the batches come in random order."""
    order = list(range(len(examples)))
    if shuffle:
        rng.shuffle(order)
        run = size * 50
        order = [i for k in range(0, len(order), run) for i in sorted(order[k:k + run], key=lambda j: len(examples[j][0]))]
    groups = [order[i:i + size] for i in range(0, len(order), size)]
    if shuffle:
        rng.shuffle(groups)
    for group in groups:
        chunk = [examples[j] for j in group]
        width = max(len(c[0]) for c in chunk)
        ids = torch.full((len(chunk), width), pad)
        labs = torch.full((len(chunk), width), -100)
        mask = torch.zeros((len(chunk), width), dtype=torch.long)
        for k, (a, b) in enumerate(chunk):
            ids[k, :len(a)] = torch.tensor(a)
            labs[k, :len(b)] = torch.tensor(b)
            mask[k, :len(a)] = 1
        yield ids, mask, labs


@torch.no_grad()
def evaluate(model, examples, tok, device):
    """Token precision and recall, overall and per class."""
    model.eval()
    classes = sorted({label.split("-", 1)[1] for label in LABELS if label != "O"})
    counts = {c: [0, 0, 0] for c in classes + ["all"]}
    for ids, mask, labs in batches(examples, 64, tok.pad_token_id, False, None):
        pred = model(input_ids=ids.to(device), attention_mask=mask.to(device)).logits.argmax(-1).cpu()
        valid = labs != -100
        for c in classes + ["all"]:
            members = torch.tensor([i for i, label in enumerate(LABELS) if label != "O" and (c == "all" or label.endswith("-" + c))])
            p, g = torch.isin(pred, members) & valid, torch.isin(labs, members) & valid
            right = p & g & (pred == labs)
            counts[c][0] += int(right.sum()); counts[c][1] += int((p & ~right).sum()); counts[c][2] += int((g & ~right).sum())
    model.train()
    return " ".join(f"{c} P {tp / max(1, tp + fp):.3f} R {tp / max(1, tp + fn):.3f}" for c, (tp, fp, fn) in counts.items())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", choices=sorted(BASES), default="small")
    parser.add_argument("--tokenizer", required=True, help="prune.py's output directory")
    parser.add_argument("--train", required=True, nargs="+")
    parser.add_argument("--valid", required=True, nargs="+")
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=2)
    parser.add_argument("--lr", type=float, default=5e-5)
    parser.add_argument("--batch", type=int, default=32)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    args = parser.parse_args()
    torch.manual_seed(args.seed)
    rng = random.Random(args.seed)
    tok = load_tokenizer(args.tokenizer)
    model = load_base(args.tokenizer, args.base).to(args.device)
    train_examples = make_examples(tok, args.train)
    valid_examples = make_examples(tok, args.valid)
    steps = args.epochs * math.ceil(len(train_examples) / args.batch)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.LambdaLR(optimizer, lambda s: min(1.0, s / (0.06 * steps)) * max(0.0, (steps - s) / (steps * 0.94)))
    print(f"{args.base}: {sum(p.numel() for p in model.parameters()) / 1e6:.1f}M parameters, {len(train_examples)} windows, {steps} steps", flush=True)
    step, start = 0, time.time()
    for epoch in range(args.epochs):
        model.train()
        for ids, mask, labs in batches(train_examples, args.batch, tok.pad_token_id, True, rng):
            loss = model(input_ids=ids.to(args.device), attention_mask=mask.to(args.device), labels=labs.to(args.device)).loss
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step(); schedule.step(); optimizer.zero_grad()
            step += 1
            if step % 200 == 0:
                print(f"step {step}/{steps} loss {loss.item():.4f} {time.time() - start:.0f}s", flush=True)
        print(f"epoch {epoch}: valid {evaluate(model, valid_examples, tok, args.device)}", flush=True)
    model.save_pretrained(args.out)
    tok.save_pretrained(args.out)


if __name__ == "__main__":
    main()
