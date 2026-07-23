/*
 * contract.c — capability contract for a freshly built artifact.
 *
 * Compiled against libsqlcipher (the SQLCipher build of SQLite) and given the
 * path to the cr-sqlite loadable extension. Asserts the capability checklist;
 * exits non-zero if any check fails. Run per platform in CI.
 *
 *   usage: contract [--sqlite3mc] <crsqlite-extension-path> <db-file-path>
 *
 * --sqlite3mc runs the same checklist against a SQLite3 Multiple Ciphers build
 * instead. Same capabilities, different unlock handshake: sqlite3mc must be put
 * into its SQLCipher-compatible mode with `PRAGMA cipher = 'sqlcipher'` +
 * `PRAGMA legacy = 4` BEFORE `PRAGMA key`. That is exactly what the Flutter
 * app's hellohq_db unlockSqlcipher()/assertSqlcipher() do, so keeping one
 * checklist for both libraries is what stops the two builds from drifting apart.
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

/* Non-zero when testing a SQLite3 Multiple Ciphers build (--sqlite3mc). */
static int sqlite3mc_mode = 0;

/* Open `path`, apply `key` (if non-NULL). Returns db handle (caller closes). */
static sqlite3 *open_keyed(const char *path, const char *key) {
  sqlite3 *db = NULL;
  if (sqlite3_open(path, &db) != SQLITE_OK) return NULL;
  if (sqlite3mc_mode) {
    /* Select the SQLCipher-compatible cipher and its v4 parameter set BEFORE
     * keying — order matters, and it must match hellohq_db::unlockSqlcipher()
     * or the two would produce databases with different crypto parameters. */
    sqlite3_exec(db, "PRAGMA cipher = 'sqlcipher';", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA legacy = 4;", NULL, NULL, NULL);
  }
  if (key) {
    char pragma[256];
    snprintf(pragma, sizeof(pragma), "PRAGMA key = '%s';", key);
    sqlite3_exec(db, pragma, NULL, NULL, NULL);
  }
  return db;
}

/* First column of the first row into `out` (set to "" on error/no row). */
static void scalar_text(sqlite3 *db, const char *sql, char *out, size_t n) {
  sqlite3_stmt *st = NULL;
  out[0] = '\0';
  if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK &&
      sqlite3_step(st) == SQLITE_ROW) {
    const unsigned char *txt = sqlite3_column_text(st, 0);
    if (txt) snprintf(out, n, "%s", (const char *)txt);
  }
  sqlite3_finalize(st);
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
  int arg = 1;
  if (arg < argc && strcmp(argv[arg], "--sqlite3mc") == 0) {
    sqlite3mc_mode = 1;
    arg++;
  }
  if (argc - arg < 2) {
    fprintf(stderr, "usage: %s [--sqlite3mc] <crsqlite-path> <db-path>\n", argv[0]);
    return 2;
  }
  const char *crsqlite = argv[arg];
  const char *dbpath = argv[arg + 1];
  remove(dbpath);
  printf("contract: %s build\n", sqlite3mc_mode ? "sqlite3mc" : "SQLCipher");

  /* 1) cipher active.
   *
   * The two libraries answer different pragmas here. `PRAGMA cipher_version` is
   * SQLCipher-proper only and returns EMPTY under sqlite3mc; sqlite3mc instead
   * reports the selected cipher via `PRAGMA cipher`. hellohq_db::assertSqlcipher()
   * checks the latter for exactly this reason, so mirror it — and assert the
   * value is `sqlcipher`, not merely non-empty. A sqlite3mc that silently fell
   * back to its own default cipher would still encrypt, but would produce
   * databases the rest of the fleet cannot open. */
  sqlite3 *db = open_keyed(dbpath, "k1");
  if (sqlite3mc_mode) {
    char cipher[64];
    scalar_text(db, "PRAGMA cipher;", cipher, sizeof(cipher));
    check(strcmp(cipher, "sqlcipher") == 0,
          "SQLCipher-compatible cipher selected (PRAGMA cipher = 'sqlcipher')");
    if (strcmp(cipher, "sqlcipher") != 0) {
      printf("        PRAGMA cipher reported \"%s\"\n", cipher);
    }
  } else {
    sqlite3_stmt *st = NULL;
    int cipher_ok = 0;
    if (sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &st, NULL) == SQLITE_OK &&
        sqlite3_step(st) == SQLITE_ROW && sqlite3_column_text(st, 0) != NULL &&
        strlen((const char *)sqlite3_column_text(st, 0)) > 0) {
      cipher_ok = 1;
    }
    sqlite3_finalize(st);
    check(cipher_ok, "cipher active (PRAGMA cipher_version non-empty)");
  }

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
