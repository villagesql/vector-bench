-- One-time datadir bootstrap, run via --init-file during phase 2 of the
-- entrypoint's initialise() — a --skip-networking start so nothing external can
-- connect while this is applied. Everything here is DURABLE in the datadir
-- (SET PERSIST -> mysqld-auto.cnf; user + extension -> catalog), so ordinary
-- boots are a plain `exec mysqld` with no --init-file and no post-start install.
--
-- Runs exactly ONCE on a fresh datadir, so statements need not be idempotent;
-- --init-file aborts startup on any error, which is what we want — a failed
-- bootstrap must fail loudly, not leave a half-initialised datadir.

-- Bench account: mysql_native_password so the client stack matches
-- MariaDB/AliSQL and cannot skew the comparison.
CREATE USER 'bench'@'%'         IDENTIFIED WITH mysql_native_password BY 'bench';
GRANT ALL PRIVILEGES ON *.* TO 'bench'@'%'         WITH GRANT OPTION;
CREATE USER 'bench'@'localhost' IDENTIFIED WITH mysql_native_password BY 'bench';
GRANT ALL PRIVILEGES ON *.* TO 'bench'@'localhost' WITH GRANT OPTION;

-- Preview gate: required before INSTALL and before every later auto-load of the
-- catalog extension. PERSIST so subsequent plain boots need no startup switch.
SET PERSIST vsql_allow_preview_extensions = ON;

-- Hypergraph optimizer: the classic optimizer never picks the custom KNN scan
-- (filesort over a full scan; can crash), so it is mandatory. PERSIST it.
SET PERSIST optimizer_switch = 'hypergraph_optimizer=on';

-- The SVECTOR + HNSW extension, discovered by name from <basedir>/lib/veb.
INSTALL EXTENSION vsql_vector;

FLUSH PRIVILEGES;
