#!/bin/bash
# The real-text release gate: runs Tests/ScrubCoreTests/RealCorpus on each
# labelled corpus kept outside the repository and fails when a number is
# worse than Tests/ScrubCoreTests/RealCorpus/baseline.json beyond its
# tolerance. Skipped, and passing, when the data is absent.
#
#   scripts/eval-gate.sh            every set, holdout excluded
#   scripts/eval-gate.sh --holdout  the holdout fifth alone: release checks only
#
# SCRUB_EVAL_DATA overrides the data directory (default ~/Work/scrub-eval-data).
set -euo pipefail
cd "$(dirname "$0")/.."
DATA="${SCRUB_EVAL_DATA:-$HOME/Work/scrub-eval-data}"
if [ ! -d "$DATA" ]; then echo "eval gate: no data at $DATA, skipped"; exit 0; fi
HOLDOUT=exclude
[ "${1:-}" = "--holdout" ] && HOLDOUT=only
swift build --build-tests
for corpus in corpus fresh; do
  [ -d "$DATA/$corpus" ] || continue
  echo "eval gate: $corpus ($HOLDOUT holdout)"
  SCRUB_REAL_CORPUS="$DATA/$corpus" SCRUB_REAL_CORPUS_HOLDOUT=$HOLDOUT swift test --skip-build --filter RealCorpus
done
