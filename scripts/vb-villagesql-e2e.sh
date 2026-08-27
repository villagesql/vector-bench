#!/usr/bin/env bash
#
# One-shot, fire-and-forget VillageSQL end-to-end: prepare -> build -> smoke
# gate -> benchmark -> result. No interactive steps once it starts.
#
#   scripts/vb-villagesql-e2e.sh [PROFILE] [ENGINES]
#     PROFILE   benchmark profile (default: smoke)
#     ENGINES   comma-separated engine list to benchmark
#               (default: villagesql,pgvector)
#
# Stages, in order; any failure aborts with a non-zero exit and a clear reason
# (so a broken build never wastes hours in the benchmark stage):
#   1. prepare-sources  — GitHub-first fetch of the branches pinned in
#                         config/engines/villagesql.yml (server_ref/extension_ref)
#   2. build-images     — server (RelWithDebInfo) + extension (Release), both targets
#   3. SMOKE GATE        — bare `docker run server`: extension installs AND a KNN
#                         query returns; FAIL FAST here if not
#   4. run               — the benchmark (ann recall/QPS + ops), via the orchestrator
#   5. report            — path to the result dir is printed at the end
#
# Typical detached use (survives logout, logs to a file):
#   nohup scripts/vb-villagesql-e2e.sh smoke villagesql,pgvector \
#     >~/vb-e2e.log 2>&1 &
#
set -uo pipefail

PROFILE="${1:-smoke}"
ENGINES="${2:-villagesql,pgvector}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$VB_ROOT"

# Python with numpy etc. — the orchestrator needs it. Prefer the ann-benchmarks
# venv used elsewhere on the box; fall back to python3 (only prepare/build need
# no numpy, so a missing venv still lets the early stages run and fail loudly at
# the run stage rather than silently).
VENV_PY="$HOME/ann-benchmarks/.venv/bin/python"
PY="$([[ -x "$VENV_PY" ]] && echo "$VENV_PY" || command -v python3)"

RUNTIME_IMG="vector-bench/villagesql-runtime:latest"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '[vb-e2e %s] %s\n' "$(ts)" "$*"; }
die() { printf '[vb-e2e %s] FATAL: %s\n' "$(ts)" "$*" >&2; exit 1; }

say "profile=$PROFILE engines=$ENGINES python=$PY"

# --- 1. prepare -----------------------------------------------------------
say "STAGE 1/5 prepare-sources (GitHub-first, pinned branches)"
bash scripts/prepare-sources.sh --engine villagesql \
  || die "prepare-sources failed"
if [[ -f sources/villagesql.source.json ]]; then
  say "sources: $(grep -oE '\"(server|extension)_commit\": \"[0-9a-f]+\"' sources/villagesql.source.json | tr '\n' ' ')"
fi

# --- 2. build -------------------------------------------------------------
say "STAGE 2/5 build-images villagesql (server + extension, both targets)"
bash scripts/build-images.sh --engine villagesql --target all \
  || die "build-images failed"

# --- 3. gate (FAIL FAST) -------------------------------------------------
# The gate IS the main path, minimal: it runs the real orchestrator on the tiny
# `gate` profile (config/profiles/gate.yml) — real ann `_start_server`/`done()`
# with the per-config server RESTART, real ops build — on a minimal grid. A
# hand-rolled "boot once" check cannot mirror the ann lifecycle (it didn't:
# villagesql got 3 ann points while every restart died "exited code 1"). Running
# the actual code path on a 2-M grid forces the restart, so a lifecycle bug fails
# HERE in a few minutes, not hours in. villagesql-only keeps it fast; the full
# run's engines/profile are the STAGE-4 args.
say "STAGE 3/5 gate: real orchestrator on the minimal 'gate' profile (villagesql)"
GATE_RUN_ID="gate-$(date -u +%Y%m%d-%H%M%S)"
"$PY" -m orchestrator.cli run \
  --profile gate --engines villagesql --phases both --force \
  --run-id "$GATE_RUN_ID" --no-report --fail-fast \
  || die "gate FAILED — the real ann/ops path broke on the minimal profile \
(run-id=$GATE_RUN_ID); a full run would fail the same way. See its logs."
say "gate PASSED — ann+ops code paths healthy on the minimal profile"

# --- 4. benchmark ---------------------------------------------------------
say "STAGE 4/5 benchmark: profile=$PROFILE engines=$ENGINES (ann + ops)"
RUN_ID="villagesql-e2e-$(date -u +%Y%m%d-%H%M%S)"
"$PY" -m orchestrator.cli run \
  --profile "$PROFILE" --engines "$ENGINES" --phases both \
  --run-id "$RUN_ID" \
  || die "benchmark run failed (run-id=$RUN_ID)"

# --- 5. report ------------------------------------------------------------
# The orchestrator writes to results/<run_id> (orchestrator/cli.py: run_dir =
# results/<run_id>). --run-id is honoured, so the path is deterministic.
say "STAGE 5/5 result"
RESULT_DIR="$VB_ROOT/results/$RUN_ID"
if [[ -d "$RESULT_DIR" ]]; then
  say "DONE — result at: $RESULT_DIR"
  ls -la "$RESULT_DIR" 2>/dev/null | head -20
  # Surface the report if one was generated (run generates it unless --no-report).
  for r in "$RESULT_DIR"/report*.md "$RESULT_DIR"/*report*.html "$RESULT_DIR"/summary*; do
    [[ -e "$r" ]] && say "report: $r"
  done
else
  say "DONE — run-id=$RUN_ID (expected results/$RUN_ID; not found — check the log above)"
fi
