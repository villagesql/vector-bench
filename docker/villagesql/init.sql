-- Runs via --init-file on every VillageSQL start. Must be idempotent.
--
-- Two jobs: create the bench account (like the other MySQL-family engines), and
-- set up the vsql_vector extension + the mandatory KNN gates.
--
-- Auth: mysql_native_password, requested explicitly, so the client stack is
-- identical to MariaDB/AliSQL (all driven through MariaDB Connector/C) and
-- cannot skew the comparison.
CREATE USER IF NOT EXISTS 'bench'@'%' IDENTIFIED WITH mysql_native_password BY 'bench';
GRANT ALL PRIVILEGES ON *.* TO 'bench'@'%' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'bench'@'localhost' IDENTIFIED WITH mysql_native_password BY 'bench';
GRANT ALL PRIVILEGES ON *.* TO 'bench'@'localhost' WITH GRANT OPTION;

-- Preview extensions must be enabled before INSTALL. SET PERSIST writes to
-- mysqld-auto.cnf so it also survives restarts on a persisted datadir.
SET PERSIST vsql_allow_preview_extensions = ON;

-- The classic optimizer never selects the custom KNN scan (it falls back to a
-- filesort over a full scan and can crash); the hypergraph optimizer is
-- mandatory. PERSIST it so every later connection inherits it. The module also
-- sets it per session as a belt-and-braces measure.
SET PERSIST optimizer_switch = 'hypergraph_optimizer=on';

-- Install the SVECTOR + HNSW extension, discovered by name from lib/veb. Only
-- ONE extension that registers the SVECTOR type may be installed: two make type
-- resolution ambiguous and the server asserts.
--
-- This file runs via --init-file, which the SERVER reads one statement at a
-- time and ABORTS startup on any error. INSTALL EXTENSION persists across
-- restarts, so on a persisted datadir a second run would error "already
-- installed" and wedge the server. It also cannot be wrapped in a prepared
-- statement (ER 1295, "not supported in the prepared statement protocol") or a
-- DELIMITER-based procedure (--init-file doesn't parse client DELIMITER). So
-- idempotency is handled OUTSIDE the SQL: the entrypoint passes --init-file
-- ONLY on the first boot (fresh datadir), never on a restart. A plain
-- INSTALL EXTENSION is therefore correct and safe here.
INSTALL EXTENSION vsql_vector;

FLUSH PRIVILEGES;
