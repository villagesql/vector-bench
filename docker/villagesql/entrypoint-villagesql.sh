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
# vsql_vector specifics, all handled by init.sql (see there for the why):
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
INIT_SQL="${VB_INIT_SQL:-/opt/vbench/init.sql}"

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

# Set to 1 by initialise() when it actually creates a fresh datadir; left 0 when
# the datadir already existed. start_server() uses this to run --init-file ONLY
# on first boot — INSTALL EXTENSION in init.sql is not idempotent and would abort
# a restart (see init.sql), and it cannot be guarded in SQL (ER 1295 / no
# DELIMITER under --init-file), so freshness is decided here instead.
initialise() {
  if [[ -d "$DATA_DIR/mysql" ]]; then
    log "data directory already initialised at $DATA_DIR"
    return 0
  fi
  log "initialising data directory at $DATA_DIR"
  "$MYSQLD" \
    --no-defaults \
    --initialize-insecure \
    --basedir="$ROOT_DIR" \
    --datadir="$DATA_DIR" \
    --log-error="$LOG_FILE" \
    $(user_args) >&2
  log "initialisation complete"
}

start_server() {
  ensure_dirs
  initialise

  local -a args=(
    --no-defaults
    --basedir="$ROOT_DIR"
    --datadir="$DATA_DIR"
    --socket="$SOCKET"
    --log-error="$LOG_FILE"
    --pid-file=/var/run/vbench/villagesql.pid
    --skip-name-resolve
    # MySQL 8.4 ships mysql_native_password DISABLED. init.sql creates the bench
    # account IDENTIFIED WITH mysql_native_password, which fails ("Plugin not
    # loaded") — and, run from --init-file, aborts startup — unless the plugin is
    # enabled here. The harness also passes this via VB_SERVER_ARGS, but hard-code
    # it too so a by-hand `docker run ... server` starts a usable server as well.
    --mysql-native-password=ON
    # The preview gate must be ON *before* the server auto-loads the persisted
    # vsql_vector extension. init.sql SET-PERSISTs it, but on a RESTART the
    # persisted extension is auto-loaded from the catalog and the parse-early
    # var from mysqld-auto.cnf is not reliably applied first (and --no-defaults
    # complicates option-file handling) — so a restart aborted with "requires
    # preview capabilities but vsql_allow_preview_extensions is OFF". Passing it
    # as an explicit startup arg guarantees it is set before extension load on
    # EVERY boot, fresh or restart, independent of PERSIST timing.
    --vsql_allow_preview_extensions=ON
    # The extension loads vectors from text literals; secure_file_priv is not
    # used by the harness but a stray non-empty default can block server-side
    # file ops during init, so pin it empty (matches the reference harness).
    --secure-file-priv=
  )
  # init.sql runs on EVERY boot via --init-file. It contains only idempotent
  # statements (CREATE USER IF NOT EXISTS, SET PERSIST gates) — safe to re-run on
  # a persisted datadir. The extension INSTALL is deliberately NOT in init.sql:
  # it is not idempotent, cannot be IF-guarded in --init-file (no conditional
  # DDL / DELIMITER; INSTALL is not preparable — ER 1295), and --init-file aborts
  # startup on any error. Instead it is done AFTER the server is up, tolerantly
  # (below), so a re-run that hits "already installed" is a harmless no-op —
  # matching how the MySQL-family and the native start_server.sh handle it.
  [[ -f "$INIT_SQL" ]] && args+=( --init-file="$INIT_SQL" )
  # --no-defaults must be first; strip any duplicate from VB_SERVER_ARGS.
  if [[ -n "${VB_SERVER_ARGS:-}" ]]; then
    for _arg in ${VB_SERVER_ARGS}; do
      [[ "$_arg" == "--no-defaults" ]] && continue
      args+=( "$_arg" )
    done
  fi
  args+=( "$@" )
  local u; u="$(user_args)"; [[ -n "$u" ]] && args+=( "$u" )

  # Run mysqld in the BACKGROUND so we can install the extension once it is up,
  # then hand the container's foreground to it via `wait` (so it stays effectively
  # PID 1 and receives signals). exec-ing mysqld directly would leave no point at
  # which to run the post-start install.
  log "starting $MYSQLD ${args[*]}"
  "$MYSQLD" "${args[@]}" &
  local mysqld_pid=$!

  # Wait for the server to accept connections, then install the extension
  # tolerantly. INSTALL EXTENSION persists in the catalog, so on a restart the
  # extension is already present and this INSTALL errors "already installed" —
  # which we swallow (|| true). Either way the extension is available afterwards.
  local ready=0 _i
  for _i in $(seq 1 60); do
    if "$(find_bin mysql)" --no-defaults -uroot --socket="$SOCKET" \
         -e "SELECT 1" >/dev/null 2>&1; then ready=1; break; fi
    # if mysqld died during startup, stop waiting and let the container exit
    kill -0 "$mysqld_pid" 2>/dev/null || break
    sleep 1
  done
  if [[ "$ready" == "1" ]]; then
    for ext in ${VB_EXTENSIONS:-vsql_vector}; do
      if "$(find_bin mysql)" --no-defaults -uroot --socket="$SOCKET" \
           -e "INSTALL EXTENSION $ext" >/dev/null 2>&1; then
        log "installed extension $ext"
      else
        log "extension $ext already installed (or install skipped) — continuing"
      fi
    done
  else
    log "WARNING: server did not become ready; skipping extension install"
  fi

  # Hand foreground to mysqld: the container lives and dies with it.
  wait "$mysqld_pid"
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
