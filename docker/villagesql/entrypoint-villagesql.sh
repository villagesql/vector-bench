#!/usr/bin/env bash
#
# Entrypoint for the vector-bench VillageSQL runtime image.
#
#   vb-entrypoint server [extra mysqld args...]   start the server (init first run)
#   vb-entrypoint init                            initialise the data directory only
#   vb-entrypoint client [args...]                open a client on the unix socket
#   vb-entrypoint <anything else>                 exec it verbatim
#
# VillageSQL is MySQL 8.4.10 based, so initialisation is
# `mysqld --initialize-insecure` (like AliSQL, unlike MariaDB).
#
# The datadir is bootstrapped ONCE, in two phases (see initialise()): phase 1
# --initialize, phase 2 a one-shot start that PERSISTs the preview gate + the
# hypergraph optimizer, creates the bench account, and INSTALLs vsql_vector — all
# durable in the datadir. After that a normal start is a plain `exec mysqld`: no
# --init-file, no preview switch, no post-start install. This matches MariaDB's
# lifecycle and is what makes the ann harness's per-config restart race-free.
#
# vsql_vector specifics (all set up in phase 2):
#   * SET PERSIST vsql_allow_preview_extensions = ON  — required to install/use
#     the preview extension;
#   * INSTALL EXTENSION vsql_vector                   — the SVECTOR + HNSW ext,
#     discovered by name from <basedir>/lib/veb/vsql_vector.veb;
#   * hypergraph optimizer ON                         — the classic optimizer
#     never selects the custom KNN scan and crashes on it.
# Exactly ONE extension that registers the SVECTOR type may be installed;
# installing two makes type resolution assert.

set -euo pipefail

ROOT_DIR="${VB_ROOT_DIR:-/opt/villagesql}"
DATA_DIR="${VB_DATA_DIR:-/var/lib/vbench/data}"
SOCKET="${VB_SOCKET:-/var/run/vbench/villagesql.sock}"
LOG_FILE="${VB_LOG_FILE:-/var/lib/vbench/villagesql.err}"

log() { printf '[vb-villagesql] %s\n' "$*" >&2; }

find_bin() {
  local name="$1" p
  for p in "$ROOT_DIR/bin/$name"; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  p="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

MYSQLD="$(find_bin mysqld)" || { log "FATAL: no mysqld under $ROOT_DIR"; exit 1; }

user_args() { [[ "$(id -u)" -eq 0 ]] && printf '%s' "--user=root"; }

ensure_dirs() {
  mkdir -p "$DATA_DIR" "$(dirname "$SOCKET")" "$(dirname "$LOG_FILE")"
}

# Two-phase bootstrap, done ONCE when the datadir is created:
#
#   Phase 1: mysqld --initialize-insecure   — create the datadir. INSTALL
#            EXTENSION cannot run here: the preview-capability framework
#            (vsql::preview::storage) is not registered during --initialize, so
#            the load fails "required capability not registered".
#   Phase 2: a normal one-shot server start that runs, then shuts down:
#              SET PERSIST vsql_allow_preview_extensions = ON;  -> mysqld-auto.cnf
#              INSTALL EXTENSION vsql_vector;                   -> catalog
#            Both are now DURABLE in the datadir. The extension is recorded in the
#            catalog and auto-loads on every subsequent boot, and the preview gate
#            is persisted so that auto-load is allowed — with no startup switch.
#
# The result: after bootstrap, an ordinary server start is a plain `exec mysqld`
# with no --init-file, no --vsql_allow_preview_extensions switch, no post-start
# install, and no background/retry — exactly MariaDB's clean lifecycle. That is
# what removes the per-config restart race: the ann harness stops and restarts
# the server on the same persisted datadir between configs, and a bare
# `exec mysqld` has nothing extra to fail on.
initialise() {
  if [[ -d "$DATA_DIR/mysql" ]]; then
    log "data directory already initialised at $DATA_DIR"
    return 0
  fi

  log "phase 1: initialising data directory at $DATA_DIR"
  "$MYSQLD" \
    --no-defaults \
    --initialize-insecure \
    --basedir="$ROOT_DIR" \
    --datadir="$DATA_DIR" \
    --log-error="$LOG_FILE" \
    $(user_args) >&2
  log "phase 1 complete"

  log "phase 2: one-shot start to persist preview gate + install vsql_vector"
  local -a p2=(
    --no-defaults
    --basedir="$ROOT_DIR"
    --datadir="$DATA_DIR"
    --socket="$SOCKET"
    --log-error="$LOG_FILE"
    --pid-file=/var/run/vbench/villagesql.pid
    --skip-name-resolve
    --mysql-native-password=ON
    # Needed for THIS phase-2 start only — it is what lets INSTALL EXTENSION
    # run. We SET PERSIST it below so later boots do not need the switch.
    --vsql_allow_preview_extensions=ON
    --secure-file-priv=
  )
  local u; u="$(user_args)"; [[ -n "$u" ]] && p2+=( "$u" )
  "$MYSQLD" "${p2[@]}" &
  local p2_pid=$! _i
  local client; client="$(find_bin mysql)"
  for _i in $(seq 1 60); do
    "$client" --no-defaults -uroot --socket="$SOCKET" -e "SELECT 1" >/dev/null 2>&1 && break
    kill -0 "$p2_pid" 2>/dev/null || { log "FATAL: phase-2 server died during startup"; tail -20 "$LOG_FILE" >&2; exit 1; }
    sleep 1
  done
  # Everything durable, done ONCE. All of it survives restarts (SET PERSIST ->
  # mysqld-auto.cnf; user + extension -> catalog), so nothing here needs to re-run
  # on a normal boot — which is what lets a normal boot be a plain exec mysqld.
  # INSTALL is fatal here (unlike the old tolerant post-start install): a fresh
  # datadir MUST get the extension, and a failure is a real bootstrap error.
  #
  #   * bench account — mysql_native_password, so the client stack matches
  #     MariaDB/AliSQL and cannot skew the comparison.
  #   * preview gate  — required before INSTALL and before every later auto-load.
  #   * hypergraph optimizer — the classic optimizer never picks the custom KNN
  #     scan (filesort over a full scan; can crash), so it is mandatory.
  "$client" --no-defaults -uroot --socket="$SOCKET" -e "
    CREATE USER IF NOT EXISTS 'bench'@'%'         IDENTIFIED WITH mysql_native_password BY 'bench';
    GRANT ALL PRIVILEGES ON *.* TO 'bench'@'%'         WITH GRANT OPTION;
    CREATE USER IF NOT EXISTS 'bench'@'localhost' IDENTIFIED WITH mysql_native_password BY 'bench';
    GRANT ALL PRIVILEGES ON *.* TO 'bench'@'localhost' WITH GRANT OPTION;
    SET PERSIST vsql_allow_preview_extensions = ON;
    SET PERSIST optimizer_switch = 'hypergraph_optimizer=on';
    INSTALL EXTENSION ${VB_EXTENSIONS:-vsql_vector};
    FLUSH PRIVILEGES;
  " || { log "FATAL: phase-2 bootstrap SQL failed"; tail -20 "$LOG_FILE" >&2; exit 1; }
  log "phase 2: persisted gate + installed ${VB_EXTENSIONS:-vsql_vector}; shutting down"
  "$client" --no-defaults -uroot --socket="$SOCKET" -e "SHUTDOWN" >/dev/null 2>&1 || true
  wait "$p2_pid" 2>/dev/null || true
  log "phase 2 complete — datadir is bootstrapped; subsequent starts are plain mysqld"
}

start_server() {
  ensure_dirs
  initialise   # two-phase bootstrap on first boot; no-op on a persisted datadir

  # After bootstrap the datadir already has the preview gate persisted and the
  # extension recorded in the catalog, so a normal start is a bare `exec mysqld`
  # — no --init-file, no --vsql_allow_preview_extensions switch, no post-start
  # install, no background/retry. This is deliberately MariaDB's clean lifecycle:
  # the ann harness restarts the server per config on the same persisted datadir,
  # and a plain exec has nothing extra that can lose the InnoDB-lock teardown race.
  local -a args=(
    --no-defaults
    --basedir="$ROOT_DIR"
    --datadir="$DATA_DIR"
    --socket="$SOCKET"
    --log-error="$LOG_FILE"
    --pid-file=/var/run/vbench/villagesql.pid
    --skip-name-resolve
    # MySQL 8.4 ships mysql_native_password DISABLED; the bench account uses it,
    # so keep it enabled on every boot. Cheap and idempotent.
    --mysql-native-password=ON
    # Harmless if the persisted gate already covers auto-load; kept as a belt-and
    # -braces guarantee that the gate is ON before the catalog extension loads,
    # independent of mysqld-auto.cnf parse-order. It is NOT what makes install
    # work anymore (that is done once in phase 2) — remove if the gate proves
    # sufficient on its own.
    --vsql_allow_preview_extensions=ON
    --secure-file-priv=
  )
  # --no-defaults must be first; strip any duplicate from VB_SERVER_ARGS.
  if [[ -n "${VB_SERVER_ARGS:-}" ]]; then
    for _arg in ${VB_SERVER_ARGS}; do
      [[ "$_arg" == "--no-defaults" ]] && continue
      args+=( "$_arg" )
    done
  fi
  args+=( "$@" )
  local u; u="$(user_args)"; [[ -n "$u" ]] && args+=( "$u" )

  # exec: the container lives and dies with mysqld, which becomes PID 1 and gets
  # signals directly — no wrapper process to forward them or race on teardown.
  log "starting $MYSQLD (plain exec) ${args[*]}"
  exec "$MYSQLD" "${args[@]}"
}

cmd="${1:-server}"; shift || true
case "$cmd" in
  server) start_server "$@" ;;
  init)   ensure_dirs; initialise ;;
  client)
    CLIENT="$(find_bin mysql)" || { log "no client binary"; exit 1; }
    exec "$CLIENT" --socket="$SOCKET" "$@"
    ;;
  *) exec "$cmd" "$@" ;;
esac
