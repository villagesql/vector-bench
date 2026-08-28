 #
# VillageSQL (MySQL 8.4.10 base) + the vsql_vector extension (SVECTOR type and
# HNSW custom index), both built from pinned branches.
#
# Targets:
#   runtime  — server binaries + the vsql_vector.veb, staged where the server
#              discovers it by name (lib/veb). Use to run VillageSQL by hand.
#   bench    — runtime + the Python stack ann-benchmarks drives.
#
# Build context is work/buildctx/villagesql/, produced by prepare-sources.sh.
# It carries TWO tars, copied as separate layers so the server and extension
# compiles cache independently (a vsql-vector-only change skips the server build):
#   server.tar     -> source/     the villagesql-server branch
#   extension.tar  -> extension/  the vsql-vector branch
#
# Two compiles happen in the builder stage: the server first (RelWithDebInfo),
# then the extension (Release) against the server's *build tree* — the extension
# links the server's dev/unstable ABI (storage_api.h), so it needs the build
# directory, not just the install prefix.
#
# The extension MUST be optimized. An empty CMAKE_BUILD_TYPE leaves the distance
# kernel at -O0 (~6-10x slower), which would make every recall/QPS number
# meaningless. This build pins Release and asserts -O3 appears in the compile
# flags before packaging; the resulting .veb is ~355 KB (an -O0 one is ~1.3 MB).

ARG BASE_IMAGE=ubuntu:24.04

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder
# ---------------------------------------------------------------------------
ARG BUILD_TYPE=RelWithDebInfo
ARG MARCH=x86-64-v3
ARG CMAKE_FLAGS=""
ARG EXTRA_CXXFLAGS=""
ARG JOBS=0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake bison pkg-config \
      libssl-dev libncurses-dev libudev-dev libaio-dev \
      libnuma-dev zlib1g-dev libtirpc-dev \
      python3 file git ca-certificates

WORKDIR /build
# The server and extension sources arrive as TWO separate tars, copied as two
# layers so their compiles cache independently. The server tar is copied here,
# before the ~30-min server compile below; the extension tar is copied later,
# after that compile, so an extension-only change (new vsql-vector commit) does
# NOT invalidate the cached server-compile layer.
COPY server.tar /tmp/server.tar
RUN tar -xf /tmp/server.tar -C /build && rm -f /tmp/server.tar
# -> /build/source (server)

# --- 1. Server (RelWithDebInfo, optimized) --------------------------------
# INSTALL_LAYOUT=STANDALONE puts the veb dir at <prefix>/lib/veb, which is where
# the server looks for extensions by name. The build/ tree is kept in the
# builder stage so the extension can link against the dev ABI.
RUN set -eux; \
    JOBS="${JOBS:-0}"; [ "$JOBS" -gt 0 ] 2>/dev/null || JOBS="$(nproc)"; \
    mkdir -p /build/source/build; cd /build/source/build; \
    : "-march goes through -DCMAKE_C/CXX_FLAGS, NOT env CFLAGS. MySQL/VillageSQL"; \
    : "CMake manages its own architecture flags and IGNORES exported CFLAGS, so"; \
    : "env CFLAGS produced an SSE-only mysqld on an AVX-512 host (verified: 0 zmm,"; \
    : "0 ymm). This is the pattern the MariaDB Dockerfile uses."; \
    cmake .. \
      -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
      -DCMAKE_C_FLAGS="-march=${MARCH} ${EXTRA_CXXFLAGS}" \
      -DCMAKE_CXX_FLAGS="-march=${MARCH} ${EXTRA_CXXFLAGS}" \
      -DCMAKE_INSTALL_PREFIX=/opt/villagesql \
      -DINSTALL_LAYOUT=STANDALONE \
      -DMYSQL_DATADIR=/var/lib/vbench/data \
      -DMYSQL_SERVER_SUFFIX="-vector-bench" \
      ${CMAKE_FLAGS} ; \
    make -j"$JOBS"; \
    make install; \
    : "Stage the extension SDK. find_package(VillageSQL) globs the build tree"; \
    : "for villagesql-extension-sdk-*/include/villagesql/vsql.h, which the"; \
    : "default 'all' target does NOT produce — the 'sdk' target does."; \
    make -j"$JOBS" sdk; \
    ls -d /build/source/build/villagesql-extension-sdk-* >/dev/null \
      || { echo "FATAL: extension SDK not staged by 'make sdk'"; exit 1; }

# Extension source copied AFTER the server compile, as its own layer. A new
# vsql-vector commit changes only this tar, so Docker reuses the cached server
# build above and re-runs only the extension compile below (~35 min -> ~2 min).
COPY extension.tar /tmp/extension.tar
RUN tar -xf /tmp/extension.tar -C /build && rm -f /tmp/extension.tar
# -> /build/extension (vsql_vector)

# --- 2. Extension (Release, MUST be optimized) ----------------------------
# Built against the server BUILD tree (VillageSQL_BUILD_DIR), not the install
# prefix: it uses storage_api.h from the dev ABI staged by 'make sdk' above.
# Verify -O3 is in the compile flags before packaging — a silent -O0 kernel is
# the single worst failure mode for this benchmark, so it is a hard build error
# here, not a runtime surprise.
RUN set -eux; \
    JOBS="${JOBS:-0}"; [ "$JOBS" -gt 0 ] 2>/dev/null || JOBS="$(nproc)"; \
    mkdir -p /build/extension/build-rel; cd /build/extension/build-rel; \
    : "-march for the extension too: its CMakeLists sets none, and the distance"; \
    : "kernel is the hot loop. Without this it compiled SSE-only (0 ymm/zmm)."; \
    : "AVX2 (the default -march=native auto-vec width on this Xeon) is used"; \
    : "deliberately, NOT AVX-512: measured, AVX-512 (-mprefer-vector-width=512)"; \
    : "was ~20% SLOWER here — HNSW is memory-latency-bound and the zmm downclock"; \
    : "on Cascade Lake outweighs the wider SIMD. -march=native => AVX2."; \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="-march=${MARCH}" \
      -DCMAKE_CXX_FLAGS="-march=${MARCH}" \
      -DVillageSQL_BUILD_DIR=/build/source/build ; \
    make -j"$JOBS" svector; \
    flags_file="$(find . -name flags.make -path '*svector.dir*' | head -1)"; \
    echo "svector flags.make: $flags_file"; \
    olevels="$(grep -oE -- '-O[0-3s]' "$flags_file" | sort -u | tr '\n' ' ')"; \
    echo "svector opt levels: ${olevels:-none}"; \
    : "Guard the -O0 trap ONLY. -O2 (RelWithDebInfo) and -O3 (Release) are both"; \
    : "fine — -O2 vs -O3 has shown no benchmark gain. An unoptimized -O0 kernel"; \
    : "(the real trap: ~6-10x slower distance kernel) or no -O flag at all fails."; \
    if echo "$olevels" | grep -qE -- '-O[123]'; then :; else \
      echo "FATAL: svector built unoptimized (no -O1/-O2/-O3; distance kernel is scalar)"; \
      cat "$flags_file"; exit 1; \
    fi; \
    make; \
    veb="$(find . -name 'vsql_vector.veb' | head -1)"; \
    [ -n "$veb" ] || { echo "FATAL: vsql_vector.veb not produced"; exit 1; }; \
    sz="$(stat -c%s "$veb")"; echo "vsql_vector.veb = ${sz} bytes"; \
    mkdir -p /opt/villagesql/lib/veb; \
    cp "$veb" /opt/villagesql/lib/veb/vsql_vector.veb; \
    echo "${MARCH}" > /opt/villagesql/.march

RUN find /opt/villagesql -type f -executable -exec file {} \; \
      | awk -F: '/ELF .* not stripped/{print $1}' | xargs -r strip --strip-debug || true

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime
# ---------------------------------------------------------------------------
LABEL org.opencontainers.image.title="vector-bench VillageSQL runtime"
ARG VILLAGESQL_TAG=unknown
ENV VB_ENGINE=villagesql \
    VB_ENGINE_TAG=${VILLAGESQL_TAG} \
    VB_ROOT_DIR=/opt/villagesql \
    VB_DATA_DIR=/var/lib/vbench/data \
    VB_SOCKET=/var/run/vbench/villagesql.sock \
    PATH=/opt/villagesql/bin:$PATH

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3t64 libncurses6 libaio1t64 libnuma1 libudev1 zlib1g libtirpc3t64 \
      ca-certificates procps tzdata \
    && useradd --system --create-home --home-dir /var/lib/vbench --shell /usr/sbin/nologin mysql 2>/dev/null || true

COPY --from=builder /opt/villagesql /opt/villagesql
COPY entrypoint-villagesql.sh /usr/local/bin/vb-entrypoint
# No init.sql: the datadir is bootstrapped once by the entrypoint's two-phase
# init (create bench user, PERSIST gates, INSTALL vsql_vector), so normal boots
# are a plain `exec mysqld` with no --init-file.
RUN chmod +x /usr/local/bin/vb-entrypoint \
    && mkdir -p "${VB_DATA_DIR}" /var/run/vbench \
    && chown -R mysql:mysql /var/lib/vbench /var/run/vbench

ENV VB_DB_USER=bench \
    VB_DB_PASSWORD=bench

EXPOSE 3306
ENTRYPOINT ["/usr/local/bin/vb-entrypoint"]
CMD ["server"]

# ---------------------------------------------------------------------------
FROM runtime AS bench
# ---------------------------------------------------------------------------
LABEL org.opencontainers.image.title="vector-bench VillageSQL + ann-benchmarks"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-dev build-essential git \
      libmariadb-dev libhdf5-dev pkg-config

# Same client stack as the MariaDB/AliSQL bench images: VillageSQL speaks the
# MySQL protocol, so it is driven through the identical MariaDB Connector/C.
# Pin MARIADB_CONFIG to the distro's copy for the same reason the AliSQL image
# does — see docker/alisql/Dockerfile.
COPY requirements-bench.txt requirements-mysql.txt /tmp/
RUN MARIADB_CONFIG=/usr/bin/mariadb_config \
    pip3 install --no-cache-dir --break-system-packages \
        -r /tmp/requirements-bench.txt -r /tmp/requirements-mysql.txt \
    && rm -f /tmp/requirements-bench.txt /tmp/requirements-mysql.txt \
    && python3 -c "import mariadb; print('Connector/Python', mariadb.__version__, 'OK')"

WORKDIR /home/app
ENV VILLAGESQL_ROOT_DIR=/opt/villagesql \
    VILLAGESQL_DB_WORKSPACE=/var/lib/vbench \
    DO_INIT_VILLAGESQL=yes
ENTRYPOINT ["python3", "-u", "run_algorithm.py"]
