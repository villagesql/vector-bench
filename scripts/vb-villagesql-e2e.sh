#!/usr/bin/env bash
#
# VillageSQL end to end, unattended: build -> gate -> benchmark.
#
#   scripts/vb-villagesql-e2e.sh [PROFILE] [ENGINES]
#     PROFILE   benchmark profile (default: smoke)
#     ENGINES   comma-separated engines to benchmark (default: villagesql,pgvector)
#
# Stages, in order; the first failure exits non-zero with the reason, so a
# broken build or a broken server lifecycle never reaches the long run:
#   1. build  -- prepare-sources (both pinned commits) + both image targets
#   2. gate   -- the real orchestrator on config/profiles/gate.yml, VillageSQL
#                only: several ann M values, so the per-configuration server
#                restart on a persisted datadir is exercised in minutes
#   3. run    -- the requested profile and engines
#
# Detached:
#   nohup scripts/vb-villagesql-e2e.sh smoke villagesql,pgvector >~/vb-e2e.log 2>&1 &

set -uo pipefail

PROFILE="${1:-smoke}"
ENGINES="${2:-villagesql,pgvector}"
VB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$VB_ROOT"

say() { printf '[vb-e2e %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { say "FATAL: $*" >&2; exit 1; }

say "profile=$PROFILE engines=$ENGINES"

say "1/3 build villagesql"
./run-benchmark.sh build --engines villagesql || die "build failed"

GATE_RUN_ID="gate-$(date -u +%Y%m%d-%H%M%S)"
say "2/3 gate (run-id $GATE_RUN_ID)"
# --force because the ann results tree is shared across runs: without it a
# second gate skips every configuration it measured before and restarts
# nothing, which is the one thing it is for. It also lifts the free-disk
# refusal, which a fashion-mnist grid this small does not need.
./run-benchmark.sh run --profile gate --engines villagesql --phases both \
  --run-id "$GATE_RUN_ID" --no-report --fail-fast --force \
  || die "gate failed (run-id $GATE_RUN_ID); a full run would fail the same way"

RUN_ID="villagesql-e2e-$(date -u +%Y%m%d-%H%M%S)"
say "3/3 run profile=$PROFILE engines=$ENGINES (run-id $RUN_ID)"
./run-benchmark.sh run --profile "$PROFILE" --engines "$ENGINES" \
  --run-id "$RUN_ID" || die "run failed (run-id $RUN_ID)"

say "done: results/$RUN_ID"
