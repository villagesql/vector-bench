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
# --initialize, phase 2 a FOREGROUND --skip-networking --init-file start whose
# init-file PERSISTs the preview gate + the hypergraph optimizer, creates the
# bench account, INSTALLs vsql_vector, and ends with SHUTDOWN — so it applies
# everything and exits on its own. Because mysqld runs the init-file before it
# accepts connections and networking is off, no client can ever connect to a
# half-bootstrapped server (one that would show no SVECTOR type and fail). All
# of it is durable in the datadir, so a normal start is a plain `exec mysqld`:
# no --init-file, no preview switch, no post-start install. This matches
# MariaDB's lifecycle and makes the ann harness's per-config restart race-free.
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
BOOTSTRAP_SQL="${VB_BOOTSTRAP_SQL:-/opt/vbench/bootstrap.sql}"

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

  log "phase 2: --init-file bootstrap (persist gate + install vsql_vector)"
  # Phase 2 runs the durable bootstrap (create bench user, PERSIST the preview
  # gate + hypergraph optimizer, INSTALL EXTENSION) via --init-file, on a
  # FOREGROUND, --skip-networking start. It is self-terminating: bootstrap.sql
  # ends with SHUTDOWN, and mysqld runs the whole init-file to completion BEFORE
  # it accepts any connection — so this mysqld applies everything and then exits
  # on its own. No background process, no socket polling, no window in which a
  # client could connect to a server that has not finished installing the
  # extension.
  #
  # Why this isolation matters: if a half-bootstrapped server were reachable, a
  # client that polls "is the server up?" (the ann harness does exactly this)
  # would connect the instant it answered — BEFORE INSTALL EXTENSION ran — see
  # no SVECTOR type, and its CREATE TABLE/INDEX would fail ("Expected a type ...
  # SVECTOR" / "Custom type operation failed"). Here there is simply no such
  # server: the only mysqld a client can ever reach is the FINAL one, started
  # after phase 2 has exited, which already has the extension. --init-file also
  # aborts startup on any error, so a bad bootstrap exits non-zero and we fail
  # loudly instead of leaving a half-initialised datadir.
  #
  # All of it is DURABLE (SET PERSIST -> mysqld-auto.cnf; user + extension ->
  # catalog), so an ordinary boot is a plain exec mysqld with no --init-file.
  local -a p2=(
    --no-defaults
    --basedir="$ROOT_DIR"
    --datadir="$DATA_DIR"
    --socket=/var/run/vbench/bootstrap.sock
    --skip-networking
    --log-error="$LOG_FILE"
    --pid-file=/var/run/vbench/bootstrap.pid
    --skip-name-resolve
    --mysql-native-password=ON
    # Lets INSTALL EXTENSION run during this bootstrap start; the init-file
    # SET-PERSISTs the gate so later boots need no switch.
    --vsql_allow_preview_extensions=ON
    --secure-file-priv=
    --init-file="$BOOTSTRAP_SQL"
  )
  local u; u="$(user_args)"; [[ -n "$u" ]] && p2+=( "$u" )
  # Foreground: mysqld applies the init-file (ending in SHUTDOWN) and exits. Its
  # exit code IS the bootstrap result — non-zero means the init-file hit an
  # error (INSTALL failed, etc.), which is fatal.
  if ! "$MYSQLD" "${p2[@]}"; then
    log "FATAL: phase-2 bootstrap failed (--init-file error)"; tail -30 "$LOG_FILE" >&2; exit 1
  fi
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
