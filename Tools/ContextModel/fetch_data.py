"""Downloads the labelled real text the context model is trained on, at pinned
revisions, and checks each file's SHA-256.

    python fetch_data.py ~/Work/scrub-train-data/raw            # permissive sources only
    python fetch_data.py ~/Work/scrub-train-data/raw --share-alike   # also Few-NERD and WikiANN

Training splits only. Scrub's real-text evaluation uses WNUT-17's test and
development splits and every section of the Broad Twitter Corpus, so only
WNUT-17's training split is fetched and the Broad Twitter Corpus not at all;
`dedupe.py` also drops any training text that matches an evaluation text.
Never fetch an evaluation split here. Licences and attribution are in
THIRD_PARTY_NOTICES.md.
"""
import argparse
import hashlib
import os
import shutil
import urllib.request

from huggingface_hub import hf_hub_download

# (file name, URL, SHA-256, licence)
GITHUB = [
    # WNUT-17 emerging entities, training split (Reddit, Twitter, YouTube, StackExchange). CC BY 4.0.
    ("wnut17train.conll", "https://raw.githubusercontent.com/leondz/emerging_entities_17/e52a2d2a71ac1a051ca2d532eef28653c5c02603/wnut17train.conll",
     "731820e13f71af324c6b55a1575ec2ce59fbaa2a0806f8f0400b98d56cd6a7a5", "CC BY 4.0"),
    # Text Anonymization Benchmark (European Court of Human Rights judgments), training split only. MIT.
    ("echr_train.json", "https://raw.githubusercontent.com/NorskRegnesentral/text-anonymization-benchmark/558e09e26d6b36f5f78440074e6a233946d98bd9/echr_train.json",
     "4aba41f8ac305ff9e93dd6f0bbc16756e57e9ace396c827931fab70e18d8c6a6", "MIT"),
    ("tab-LICENSE.txt", "https://raw.githubusercontent.com/NorskRegnesentral/text-anonymization-benchmark/558e09e26d6b36f5f78440074e6a233946d98bd9/LICENSE.txt",
     "9569b31acf50e1cb3f38f47220f2c3a42f533e07e72fe2d18c2871e89098a8c7", "MIT"),
    # The Broad Twitter Corpus is not used: Scrub's real-text evaluation samples
    # every one of its sections (A, B, E–H), so no part of it is training text.
]
# WikiANN languages: English, the non-Latin scripts Scrub reads names in, and Turkish and Polish.
WIKIANN = {
    "en": "ea0f7f3ca6e740b2a74159204debd74696447de0d55cb3f4134167cbb75922fd",
    "ru": "ca6bf711bb4acbac798dd8f44138eec4a915f9912454ca3935a3df6806f35a0d",
    "el": "b8ea3b88b137e51f20a708f25ab944b30d675906609d783e5f0b8b941067e037",
    "he": "08608ff58fb31cb9a5bc91a691ac63a12d717b09c624aa0d9ef2c1e3bb97bcaf",
    "ar": "774beeb2584ce4966c0c2a993c3f5e7aa0e27b6d96044d4555d341e665b47a87",
    "hi": "210a5de84150102a055635a924c0c2750b1b1b865b8a0c35f02a70580bd38ab1",
    "th": "1c0f44f539c79690aefd4ee7fa575fcc0594e9a43a611ff480922ea4b19a76de",
    "ja": "f98427148e34316fe33c8403b52bfea4c726c5a741c575ed6398dffc7b3dd982",
    "zh": "6dc687ea710dbb1b577123b8df880dae5b862f54832838848a5d4a1c27dbf558",
    "ko": "776c9d9c69cb9dfbcf1926a11212586a643ffbf972c874cb80b3b488ea1aa250",
    "tr": "b2693d01b7be90ece7a60ddb837bf5a800b7ce78c5c2fbf677295da4f9cab1fb",
    "pl": "f409c82b163a0defd26bd9ff59814581223c99abd83792833868b44e83708c41",
}
HF = [
    # Few-NERD, supervised setting, training split (English Wikipedia). CC BY-SA 4.0: share-alike.
    ("few-nerd-train.parquet", "DFKI-SLT/few-nerd", "205f3e9c9f3577ea2561d43f2f62dc249ab92d5b", "supervised/train-00000-of-00001.parquet",
     "6ccb192b1accd3d1754db2244d18ddf64040357fb5b9076a338ec421a72d7d61", "CC BY-SA 4.0"),
] + [
    # WikiANN (Rahimi et al. 2019 splits), training split per language (Wikipedia). Wikipedia text is CC BY-SA: share-alike.
    (f"wikiann-{lang}-train.parquet", "unimelb-nlp/wikiann", "f0a3be6dc5564c0cc4150bb660144800a1f539d4", f"{lang}/train-00000-of-00001.parquet", digest, "CC BY-SA (Wikipedia)")
    for lang, digest in WIKIANN.items()
]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--share-alike", action="store_true", help="also fetch the CC BY-SA sources (Few-NERD, WikiANN)")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for name, url, _, _ in GITHUB:
        path = os.path.join(args.out, name)
        if not os.path.exists(path):
            request = urllib.request.Request(url, headers={"User-Agent": "scrub-tools/1.0"})
            with urllib.request.urlopen(request) as response, open(path, "wb") as f:
                shutil.copyfileobj(response, f)
    if args.share_alike:
        for name, repo, revision, file, _, _ in HF:
            path = os.path.join(args.out, name)
            if not os.path.exists(path):
                shutil.copyfile(hf_hub_download(repo, file, repo_type="dataset", revision=revision), path)
    expected = {name: digest for name, _, digest, _ in GITHUB} | {name: digest for name, _, _, _, digest, _ in HF}
    for name in sorted(os.listdir(args.out)):
        if name not in expected:
            continue
        actual = sha256(os.path.join(args.out, name))
        status = "ok" if actual == expected[name] else ("unpinned" if not expected[name] else "MISMATCH")
        print(f"{status:9} {actual}  {name}")


if __name__ == "__main__":
    main()
