#!/bin/bash
# The real-text release gate: runs Tests/ScrubCoreTests/RealCorpus on each
# labelled corpus kept outside the repository and fails when a number is
# worse than Tests/ScrubCoreTests/RealCorpus/baseline.json beyond its
# tolerance. Skipped, and passing, when the data is absent, except with
# --strict, which releases use: then both corpora must be there, hold
# documents, and have a baseline for the slice run, or the gate fails.
#
#   scripts/eval-gate.sh                     every set, holdout excluded
#   scripts/eval-gate.sh --holdout           the holdout fifth alone: release checks only
#   scripts/eval-gate.sh --strict [--holdout]
#
# SCRUB_EVAL_DATA overrides the data directory (default ~/Work/scrub-eval-data).
set -euo pipefail
cd "$(dirname "$0")/.."
DATA="${SCRUB_EVAL_DATA:-$HOME/Work/scrub-eval-data}"
HOLDOUT=exclude STRICT=0
for arg in "$@"; do
  case "$arg" in
    --holdout) HOLDOUT=only ;;
    --strict) STRICT=1 ;;
    *) echo "eval gate: unknown option $arg" >&2; exit 2 ;;
  esac
done
for corpus in corpus fresh; do
  if [ ! -d "$DATA/$corpus" ]; then
    if [ "$STRICT" = 1 ]; then echo "eval gate: no $corpus data at $DATA/$corpus; a release needs both corpora" >&2; exit 1; fi
    echo "eval gate: no $corpus data at $DATA/$corpus, skipped"
  fi
done
swift build --build-tests
for corpus in corpus fresh; do
  [ -d "$DATA/$corpus" ] || continue
  echo "eval gate: $corpus ($HOLDOUT holdout)"
  SCRUB_REAL_CORPUS="$DATA/$corpus" SCRUB_REAL_CORPUS_HOLDOUT=$HOLDOUT SCRUB_REAL_CORPUS_STRICT=$STRICT swift test --skip-build --filter RealCorpus
done
