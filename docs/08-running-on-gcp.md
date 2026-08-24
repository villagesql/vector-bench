# Running vector-bench on the GCP rig (with VillageSQL)

Field notes from bringing up the VillageSQL + vsql-vector engine on the
`villagesql-benchmarking` GCP project. These are the things that cost time the
first time; read them before a run.

---

## The rig

GCP project **`villagesql-benchmarking`**, zone `us-central1-a`, account
`tomas@villagesql.com`. Instances are left **STOPPED** to save cost — start only
what you need, stop when done.

- **mysql-server** (n2-standard-8, Intel Xeon **Cascade Lake**, 4 physical cores
  / 8 threads, 32 GB RAM, ~100 GB disk) — **this is the benchmark host.**
  vector-bench is self-contained: build, fetch, and run all happen here. The CPU
  has full **AVX-512** (avx512f/dq/cd/bw/vl + vnni) and AVX2.
- **mysql-builder** (n2-standard-16) — the VillageSQL *server-image LTO* box for
  other work. **Not needed for vector-bench** (images build on mysql-server).
  Keep it stopped.

`mysql-server` was resized to n2-standard-8 specifically for the ~32 GB the 1M
vector datasets need.

---

## Zone stockouts

Starting a stopped VM can fail with `ZONE_RESOURCE_POOL_EXHAUSTED` — GCP is out
of n2-standard-8 in us-central1-a at that moment. It usually clears in minutes.
Retry the `start`; a single `gcloud compute instances start` blocks until it
succeeds or fails, so a retry loop is enough. If it drags, `gcloud compute
instances move` to us-central1-c (has capacity) works — the internal IP
10.128.0.2 is regional and preserved, and vector-bench is single-host so the
zone doesn't affect results.

---

## ssh is flaky under load — work around it

IAP ssh to these boxes returns exit 255 intermittently, and **much** more often
when the box is under a heavy build (load 7-8 saturates the 8 threads). Rules
that made this survivable:

- **Retry every command 3-5×.** A trivial `echo` probe often connects when a
  heavier command just failed.
- **`scp` is more reliable than interactive ssh** — push files with it.
- **Detached launches must use `setsid CMD </dev/null >log 2>&1 &`.** A plain
  `nohup CMD &` over ssh makes the session *hang* (ssh waits on the backgrounded
  process's file descriptors) — it looks like the 255 flakiness but is actually
  the launch never returning. `setsid` + `</dev/null` detaches cleanly.
- **Never put `pkill -9 -f build-images.sh` (or any broad `pkill`) in an ssh
  one-liner.** It can match/kill the session's own shell or the gcloud tunnel
  helper, so the command "fails" (255) even though the box is fine. To check
  what's running, use `ps -eo pid,args | grep -v grep` instead; a `pgrep -f
  <pat>` from inside a script that *contains* `<pat>` self-matches and waits on
  itself forever (this bit us twice — the make wait-loop and the build killer).

---

## Host prerequisites (what the README understates)

The README says the host needs only PyYAML. In practice the orchestrator's
`fetch` and `run` import **numpy** (and h5py for datasets). On mysql-server the
old ann-benchmarks venv already has them:

```bash
VENV=~/ann-benchmarks/.venv/bin/python
$VENV -c 'import numpy, yaml, h5py; print("ok")'
# run the orchestrator through it:
$VENV -m orchestrator.cli run --profile smoke --engines villagesql --phases ann ...
```

Docker needs the `sg docker -c "..."` wrapper (the `tomas` user is in the docker
group but not re-logged-in).

## Datasets: copy, don't symlink

fashion-mnist is already at `~/ann-benchmarks/data/`. **Copy** it into
`vector-bench/datasets/` — do **not** symlink. The ann container bind-mounts only
`datasets/`, so a symlink pointing at `~/ann-benchmarks/data/` **dangles inside
the container**, ann-benchmarks then tries to download it, and the container has
`network=none` → `URLError: Temporary failure in name resolution`.

```bash
cp ~/ann-benchmarks/data/fashion-mnist-784-euclidean.hdf5 \
   ~/vector-bench/datasets/
```

---

## Building the VillageSQL image — the traps

The image compiles the server *and* the vsql-vector extension from source
(`docker/villagesql/`). Sources come from two branches, git-archived into one
tarball by `prepare-sources.sh` (server `tomas/deb-6-optimizer-scan`, extension
`tomas/deb-absolute-minimal-bridge`).

Five things that each cost a build cycle before they were fixed:

1. **Hypergraph optimizer is a COMPILE flag, not a debug thing.** The custom KNN
   scan requires the hypergraph optimizer (the classic optimizer crashes on it),
   but `WITH_HYPERGRAPH_OPTIMIZER` defaults ON *only for debug builds*. In an
   optimized (RelWithDebInfo) build you must pass `-DWITH_HYPERGRAPH_OPTIMIZER=ON`
   explicitly, or `SET optimizer_switch='hypergraph_optimizer=on'` is rejected
   with *"does not yet support use in non-debug builds."* No debug build needed —
   it's a plain option override.

2. **MySQL 8.4 ships `mysql_native_password` DISABLED.** The bench account is
   created `IDENTIFIED WITH mysql_native_password`; without the plugin loaded
   that errors (1524) and, run from `--init-file`, aborts startup. Pass
   `--mysql-native-password=ON` (it's in the engine yml's `server.common`, and
   hard-coded in the entrypoint as a belt-and-suspenders).

3. **-march must go through `-DCMAKE_C_FLAGS`/`-DCMAKE_CXX_FLAGS`, not env
   CFLAGS.** MySQL/VillageSQL's CMake manages its own arch flags and *ignores*
   exported `CFLAGS`. Setting `export CFLAGS=-march=native` produced an
   **SSE-only** mysqld and extension on an AVX-512 host (verified: 0 zmm, 0 ymm)
   — a silent ~4× throughput understatement. Use the cache-var form (this is what
   the MariaDB Dockerfile does).

4. **The extension needs `-mprefer-vector-width=512` for AVX-512.** With
   `-march=native` alone GCC caps the *auto-vectorized* distance loop at 256-bit
   (AVX2) on this Xeon out of downclock caution. mysqld got AVX-512 anyway (it has
   explicit intrinsics); the extension relies on auto-vec, so add
   `-mprefer-vector-width=512`. (-O2 vs -O3 makes no measured difference; only the
   **-O0 trap** matters — an unoptimized distance kernel is ~6-10× slower. The
   Dockerfile hard-fails if the kernel isn't at least `-O1`.)

5. **`make sdk` before building the extension.** The extension's
   `find_package(VillageSQL)` globs `<build>/villagesql-extension-sdk-*/include/
   villagesql/vsql.h`, which the default `all` target does **not** produce — the
   `sdk` target does. Build order: server `make` → `make sdk` → extension.

### Verify the SIMD width before trusting any number

The `.march` marker file only records the literal string `native`, not the
resolved ISA — **do not trust it**. Disassemble instead. The `.veb` is a **GNU
tar**; unpack it to get the `.so`:

```bash
docker create --name c vector-bench/villagesql-bench:latest
docker cp c:/opt/villagesql/lib/veb/vsql_vector.veb /tmp/x.veb
docker cp c:/opt/villagesql/bin/mysqld /tmp/mysqld
docker rm c
tar -xf /tmp/x.veb -C /tmp/veb            # -> /tmp/veb/lib/vsql_vector.so
objdump -d /tmp/veb/lib/vsql_vector.so | grep -c '%zmm'   # AVX-512
objdump -d /tmp/veb/lib/vsql_vector.so | grep -c '%ymm'   # AVX2
objdump -d /tmp/mysqld                   | grep -c '%zmm'
```

Do the **same check on every engine** (MariaDB, AliSQL, pgvector) before a
cross-engine comparison, or "MariaDB vs VillageSQL" can silently be a comparison
of compiler flags. AliSQL's Dockerfile uses the same env-CFLAGS pattern that
failed for VillageSQL — verify its mysqld actually got AVX-512.

### Rebuilds are cheap if you only touch the extension

Changing only the extension's cmake step keeps the ~40-minute **server** layer
(the `docker build` step that compiles mysqld) **cached** — Docker jumps straight
to the extension + Python-stack steps, ~2-3 minutes. The full server recompile
(~40 min on 8 cores) only happens when the server sources or its build args
change. `-DWITH_UNIT_TESTS=OFF` keeps the image build from compiling the gunit
tests (a standalone `make` on the builder *does* build them and looks stuck at
"100%" for a long time — that's the unit-test link phase, harmless).

---

## The vsql-vector SQL surface (for the adapter / by hand)

```sql
-- gates (set by init.sql at startup; PERSISTed)
SET PERSIST vsql_allow_preview_extensions = ON;
INSTALL EXTENSION vsql_vector;              -- by NAME; exactly ONE extension may
                                            -- register SVECTOR, or type resolution asserts
SET GLOBAL optimizer_switch = 'hypergraph_optimizer=on';

CREATE TABLE t (id INT PRIMARY KEY, v SVECTOR(784) NOT NULL) ENGINE=InnoDB;
CREATE INDEX ix ON t (v hnsw_l2) USING EXTENDED(hnsw) WITH (M=16, ef_construction=200);
-- metric modifiers: hnsw_l2 | hnsw_cosine | hnsw_l1 | hnsw_inner_product
-- ef_construction >= M is enforced.

INSERT INTO t VALUES (1,'[0.1,0.2,...]'), ...;   -- vector as TEXT literal; BATCH ~1000
                                                 -- rows/stmt or exceed max_allowed_packet

SET GLOBAL vsql_vector.ef_search = 100;    -- GLOBAL-only (session SET → ER 1229); unquoted

SELECT id FROM t ORDER BY L2_DISTANCE(v, '[...]') LIMIT 10;
-- metric fns: L2_DISTANCE | COSINE_DISTANCE | L1_DISTANCE | INNER_PRODUCT (DESC for IP)
```

Two adapter specifics that matter:

- **The query vector must be inlined as a literal**, not a bound `%s` parameter —
  the custom index routes only when the optimizer sees
  `ORDER BY DIST(col, '<literal>') LIMIT k`.
- **Confirm the index actually routed** with `EXPLAIN`: a routed scan prints
  `Custom index distance scan on <ix>`. Its absence means a brute-force fallback
  (exact results at ~16 QPS), which would read as "accurate but slow."

---

## Fairness: server config across engines

The resource layer (1-core cpuset, container memory limit, memory fractions) is
**shared** across engines — that part is equal by construction. Per-engine server
*flags* differ by knob name, which is fine. Two things to get right for
VillageSQL specifically:

- **Graph-cache memory.** MariaDB (`mhnsw_max_cache_size`) and AliSQL
  (`vidx_hnsw_cache_size`) have a *separate* tunable HNSW graph cache; the harness
  sizes it from the `graph_cache_fraction`. VillageSQL's graph is
  **InnoDB-buffer-pool-resident** — no separate cache. So VillageSQL must **absorb
  the graph-cache fraction into its buffer pool** (an `if engine=="villagesql"`
  block in `config.py`, mirroring the existing pgvector rule), or it gets ~half
  the resident memory the others do. Critical for the out-of-core / RAM-cap study.
- **Isolation.** MariaDB/AliSQL run READ-COMMITTED; VillageSQL's yml sets
  `--transaction-isolation=READ-COMMITTED` for parity.

Remaining documented asymmetry: SIMD width — see the objdump check above; get all
engines to the same ISA or note it.

---

## A working sequence, start to finish

```bash
# 0. start the box (retry on stockout)
gcloud compute instances start mysql-server --zone=us-central1-a

# 1. get vector-bench + the villagesql adapter onto the box (until it's a branch,
#    clone the base and copy the adapter files over)

# 2. prepare sources (git-archives both VillageSQL branches; ~30s)
cd ~/vector-bench && ./scripts/prepare-sources.sh --engine villagesql

# 3. build the image (~40 min first time; ~2-3 min for extension-only rebuilds)
setsid sg docker -c './scripts/build-images.sh --engine villagesql \
  --target bench --march native --jobs 8' </dev/null >~/build.log 2>&1 &

# 4. VERIFY SIMD in the built binaries (objdump, see above) — do not skip

# 5. dataset (copy, don't symlink)
cp ~/ann-benchmarks/data/fashion-mnist-784-euclidean.hdf5 ~/vector-bench/datasets/

# 6. sanity-start the image and run a hand KNN query (catches startup issues in
#    seconds vs. waiting out a full run) — confirm EXPLAIN shows the custom scan

# 7. run (through the venv python that has numpy)
VENV=~/ann-benchmarks/.venv/bin/python
setsid sg docker -c "cd ~/vector-bench && ./scripts/prepare-harness.sh && \
  $VENV -m orchestrator.cli run --profile smoke --engines villagesql \
  --phases ann --resource-pass normalized" </dev/null >~/run.log 2>&1 &

# 8. read recall/QPS
$VENV - <<'PY'
import json
for l in open('results/<run>/report/records.jsonl'):
    r=json.loads(l)
    if 'recall_at_k' in r:
        print(r['engine'], 'ef', r.get('ef_search'), 'recall', r['recall_at_k'],
              'qps', r['qps'], 'idx_used', r.get('vector_index_used'))
PY

# 9. STOP the box when done (it bills while running)
gcloud compute instances stop mysql-server --zone=us-central1-a
```

---

## Gotchas hit in practice (read this — each cost a cycle)

**Images — build `--target all`, not just `bench`.** The ann phase uses the
`<engine>-bench` image (server + Python in one container); the ops phase uses the
`<engine>-runtime` image (server alone, separate client container). Building only
`--target bench` makes the ops phase fail *"image vector-bench/<engine>-runtime
not found"*. Bit both VillageSQL and pgvector. The runtime target is all cached
layers of the same Dockerfile, so `--target all` costs nothing extra.

**Workload selection is profile-only — there is no `--workloads` flag.** To run a
subset (e.g. build + concurrency, skipping churn/filtered), set `ops.workloads:
[build, concurrency]` in the profile. Passing `--workloads` to `run` errors with
"unrecognized arguments".

**VillageSQL (this vsql-vector branch) is INSERT + KNN only.** No DELETE (the
churn workload's `DELETE` crashes the server — "Lost connection during query")
and no filtered/hybrid search (a `WHERE` alongside the KNN `ORDER BY` is ignored,
yielding ~0.10 recall). Run **build + concurrency only** for VillageSQL until
UPDATE/DELETE and filtered search land. (`filtered_search: false`,
`delete_supported: false` in the engine yml.)

**Silent result reuse — verify every re-measurement.** Two independent caches will
hand you *old* numbers while looking like a fresh run:
- *Stale datadir.* The ops server container writes its datadir **root-owned**, and
  the harness's `shutil.rmtree(state_dir, ignore_errors=True)` runs as your user,
  so cleanup fails silently and the next start reuses (or dies on) the old datadir.
  Fix: `sudo rm -rf <vector-bench>/state`; the ops runner also `docker volume rm`s
  the engine's named volumes.
- *Stale ann hdf5.* ann-benchmarks caches results at
  `results/annb/<pass>/<fingerprint>/<dataset>/<k>/<engine>/*.hdf5`. The fingerprint
  is resource-based, **not image-based**, so after rebuilding the engine (e.g.
  AVX2 vs AVX-512) a re-run prints *"nothing to do: already have results"* and
  never starts the server. Delete those hdf5 to force a real re-measure.
- After any re-run, confirm the log shows **`starting <engine>`**, a fresh **`load
  complete`**, and **`new result file(s)`** — not `nothing to do` — and that the
  numbers actually changed.

**ef_construction is set for every engine from one neutral knob.** Historically the
ops path passed `--ef-construction` only to pgvector, so VillageSQL fell back to a
driver default — correct only by coincidence when both were 200. Now `ops_pass`
sets it for all engines (`ops.ef_construction` → `pgvector_ef_construction` → 200);
set `ops.ef_construction` in the profile and both engines build to the same graph
quality by construction.

**SIMD: AVX2 beat AVX-512 here.** On this Cascade Lake, `-mprefer-vector-width=512`
made the extension's distance kernel ~20% *slower* — HNSW is memory-latency-bound
and the AVX-512 downclock outweighs the wider SIMD. Use plain `-march=native`
(AVX2) for the extension. (mysqld still gets AVX-512 via its own intrinsics; that
is fine.) Always objdump-verify — see above.

**Driving the box over flaky ssh:**
- `scp` does **not** set the execute bit. `chmod +x` any script you scp before
  running it, or `setsid sg docker -c '~/script.sh'` fails "Permission denied"
  (and the setsid hides it — the launch echo still prints).
- Detached launches: `setsid CMD </dev/null >log 2>&1 &`. A plain `nohup CMD &`
  over ssh **hangs the session** (ssh waits on the backgrounded fds).
- Never put `pkill -f build-images.sh` (or any broad `pkill`) in an ssh one-liner —
  it can kill the session's own shell / tunnel helper and the command "fails" (255)
  though the box is fine. Use `ps -eo pid,args | grep -v grep` to inspect instead.

## Sanity numbers (fashion-mnist-784, 60k, M=16, ef_construction=200)

A healthy VillageSQL run looks like this — recall rises with ef_search, QPS
falls, and every point reports `vector_index_used: true`:

| ef_search | recall@10 | QPS |
| ---: | ---: | ---: |
| 10  | ~0.93  | ~1100 |
| 40  | ~0.99  | ~650  |
| 160 | ~0.999 | ~300  |

If recall is flat at 1.0 across ef_search, the index did **not** route (you're
measuring a brute-force scan) — check the EXPLAIN plan.
