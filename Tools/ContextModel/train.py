"""Fine-tunes the base encoder as the context model's token tagger.

    python train.py --tokenizer pruned/ --train train.jsonl --valid valid.jsonl --out checkpoint/

Each document becomes windows of 128 pieces (126 between the start and end
markers, each window 96 pieces on from the last), labelled B/I per class from
the generated spans. The shipped model used the defaults below.
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

# The base encoder, at the revision the shipped model was built from.
BASE_MODEL, BASE_REVISION = "microsoft/Multilingual-MiniLM-L12-H384", "6e8c1ec6b4ec4e3fc6eb7d2cd834fcd582b61daf"
L2I = {label: i for i, label in enumerate(LABELS)}
WINDOW, STRIDE = 128, 96


def load_tokenizer(pruned):
    return PreTrainedTokenizerFast(tokenizer_file=os.path.join(pruned, "tokenizer.json"), bos_token="<s>", eos_token="</s>",
                                   unk_token="<unk>", pad_token="<pad>", cls_token="<s>", sep_token="</s>")


def load_base(pruned):
    """The base encoder with a fresh classifier, its embeddings cut to the pruned pieces."""
    model = AutoModelForTokenClassification.from_pretrained(BASE_MODEL, revision=BASE_REVISION, num_labels=len(LABELS))
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


def make_examples(tok, path, limit=None):
    examples = []
    for n, line in enumerate(open(path)):
        if limit and n >= limit:
            break
        d = json.loads(line)
        for _, ids, offs in windows(tok, d["text"]):
            examples.append(([tok.cls_token_id] + ids + [tok.sep_token_id], [-100] + labels_for(offs, d["spans"]) + [-100]))
    return examples


def batches(examples, size, pad, shuffle, rng):
    order = list(range(len(examples)))
    if shuffle:
        rng.shuffle(order)
    for i in range(0, len(order), size):
        chunk = [examples[j] for j in order[i:i + size]]
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
    model.eval()
    tp = fp = fn = 0
    for ids, mask, labs in batches(examples, 64, tok.pad_token_id, False, None):
        pred = model(input_ids=ids.to(device), attention_mask=mask.to(device)).logits.argmax(-1).cpu()
        valid = labs != -100
        p, g = (pred != 0) & valid, (labs > 0) & valid
        tp += int((p & g & (pred == labs)).sum()); fp += int((p & ~(g & (pred == labs))).sum()); fn += int((g & ~(p & (pred == labs))).sum())
    return f"token P {tp / max(1, tp + fp):.3f} R {tp / max(1, tp + fn):.3f}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokenizer", required=True, help="prune.py's output directory")
    parser.add_argument("--train", required=True)
    parser.add_argument("--valid", required=True)
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
    model = load_base(args.tokenizer).to(args.device)
    train_examples = make_examples(tok, args.train)
    valid_examples = make_examples(tok, args.valid)
    steps = args.epochs * math.ceil(len(train_examples) / args.batch)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.LambdaLR(optimizer, lambda s: min(1.0, s / (0.06 * steps)) * max(0.0, (steps - s) / (steps * 0.94)))
    print(f"{sum(p.numel() for p in model.parameters()) / 1e6:.1f}M parameters, {len(train_examples)} windows, {steps} steps", flush=True)
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
