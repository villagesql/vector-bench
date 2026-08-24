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
    # The extension loads vectors from text literals; secure_file_priv is not
    # used by the harness but a stray non-empty default can block server-side
    # file ops during init, so pin it empty (matches the reference harness).
    --secure-file-priv=
  )
  # init.sql performs the extension install + gate PERSISTs. It must run before
  # the harness connects; --init-file runs it during startup as a privileged
  # bootstrap connection, so INSTALL EXTENSION and SET PERSIST are permitted.
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

  log "exec $MYSQLD ${args[*]}"
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
