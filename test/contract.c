/*
 * contract.c — capability contract for a freshly built artifact.
 *
 * Compiled against libsqlcipher (the SQLCipher build of SQLite) and given the
 * path to the cr-sqlite loadable extension. Asserts the capability checklist;
 * exits non-zero if any check fails. Run per platform in CI.
 *
 *   usage: contract <crsqlite-extension-path> <db-file-path>
 *
 * Coverage = capability x platform completeness (this list, on every platform),
 * not source line-coverage (we do not author the upstream sources).
 */
#include "sqlite3.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int failures = 0;
static void check(int ok, const char *name) {
  printf("  %s  %s\n", ok ? "PASS" : "FAIL", name);
  if (!ok) failures++;
}

/* Open `path`, apply `key` (if non-NULL). Returns db handle (caller closes). */
static sqlite3 *open_keyed(const char *path, const char *key) {
  sqlite3 *db = NULL;
  if (sqlite3_open(path, &db) != SQLITE_OK) return NULL;
  if (key) {
    char pragma[256];
    snprintf(pragma, sizeof(pragma), "PRAGMA key = '%s';", key);
    sqlite3_exec(db, pragma, NULL, NULL, NULL);
  }
  return db;
}

/* Run `sql`; return its SQLite result code. */
static int run(sqlite3 *db, const char *sql) {
  return sqlite3_exec(db, sql, NULL, NULL, NULL);
}

/* First column of the first row as int64 (-1 on error). */
static long long scalar(sqlite3 *db, const char *sql) {
  sqlite3_stmt *st = NULL;
  long long v = -1;
  if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK &&
      sqlite3_step(st) == SQLITE_ROW) {
    v = sqlite3_column_int64(st, 0);
  }
  sqlite3_finalize(st);
  return v;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <crsqlite-path> <db-path>\n", argv[0]);
    return 2;
  }
  const char *crsqlite = argv[1];
  const char *dbpath = argv[2];
  remove(dbpath);

  /* 1) cipher active */
  sqlite3 *db = open_keyed(dbpath, "k1");
  sqlite3_stmt *st = NULL;
  int cipher_ok = 0;
  if (sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &st, NULL) == SQLITE_OK &&
      sqlite3_step(st) == SQLITE_ROW && sqlite3_column_text(st, 0) != NULL &&
      strlen((const char *)sqlite3_column_text(st, 0)) > 0) {
    cipher_ok = 1;
  }
  sqlite3_finalize(st);
  check(cipher_ok, "cipher active (PRAGMA cipher_version non-empty)");

  /* 2) write + key round-trip */
  check(run(db, "CREATE TABLE t(id INTEGER NOT NULL PRIMARY KEY, v TEXT);") == SQLITE_OK &&
        run(db, "INSERT INTO t VALUES(1,'secret');") == SQLITE_OK,
        "write to keyed db");
  sqlite3_close(db);
  db = open_keyed(dbpath, "k1");
  check(scalar(db, "SELECT count(*) FROM t;") == 1, "reopen with correct key reads data");
  sqlite3_close(db);

  /* 3) wrong key rejected */
  db = open_keyed(dbpath, "WRONG");
  check(run(db, "SELECT count(*) FROM t;") == SQLITE_NOTADB, "wrong key rejected (SQLITE_NOTADB)");
  sqlite3_close(db);

  /* 4) rekey */
  db = open_keyed(dbpath, "k1");
  check(run(db, "PRAGMA rekey = 'k2';") == SQLITE_OK, "rekey");
  sqlite3_close(db);
  db = open_keyed(dbpath, "k2");
  check(scalar(db, "SELECT count(*) FROM t;") == 1, "reopen with new key after rekey");
  sqlite3_close(db);
  db = open_keyed(dbpath, "k1");
  check(run(db, "SELECT count(*) FROM t;") == SQLITE_NOTADB, "old key rejected after rekey");
  sqlite3_close(db);

  /* 5) cr-sqlite loads (per-connection, AFTER key) */
  db = open_keyed(dbpath, "k2");
  sqlite3_enable_load_extension(db, 1);
  char *errmsg = NULL;
  int load_rc = sqlite3_load_extension(db, crsqlite, "sqlite3_crsqlite_init", &errmsg);
  check(load_rc == SQLITE_OK, "cr-sqlite loadable extension loads");
  if (errmsg) sqlite3_free(errmsg);

  /* 6) CRR changeset round-trip */
  int crr_ok =
      run(db, "CREATE TABLE foo(id INTEGER NOT NULL PRIMARY KEY, a TEXT);") == SQLITE_OK &&
      run(db, "SELECT crsql_as_crr('foo');") == SQLITE_OK &&
      run(db, "INSERT INTO foo VALUES(1,'x');") == SQLITE_OK &&
      run(db, "UPDATE foo SET a='y' WHERE id=1;") == SQLITE_OK &&
      scalar(db, "SELECT count(*) FROM crsql_changes;") >= 1;
  check(crr_ok, "cr-sqlite CRR changeset round-trip");
  run(db, "SELECT crsql_finalize();");
  sqlite3_close(db);

  printf("%s (%d failure%s)\n", failures ? "CONTRACT FAILED" : "CONTRACT OK",
         failures, failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}
