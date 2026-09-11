/*
 * crsql_changes_fuzzer.c — libFuzzer target for cr-sqlite's crsql_changes
 * write path, the surface that applies replicated changes.
 *
 * Each input is fed as the `pk` (packed primary-key) blob of a row inserted
 * into the crsql_changes virtual table — byte-for-byte the path a peer's sync
 * data takes on apply (hellohq_db.applyChangeset → INSERT INTO crsql_changes).
 * cr-sqlite's unpack_columns parses that blob; a malformed one used to read
 * past the buffer and panic (abort), because the extension is built
 * panic=abort. patches/0001-crsqlite-bounds-check-unpack-columns.patch fixes
 * that, and THIS harness is the regression guard: run it and a reintroduced
 * unchecked read shows up as a crash within seconds.
 *
 * Build: linked against the STATIC cr-sqlite bundle, which embeds SQLite and
 * auto-registers cr-sqlite via SQLITE_EXTRA_INIT=core_init — so a plain
 * sqlite3_open has the crsql_* functions available, no runtime load needed.
 * (Encryption is irrelevant to this parser, so we do not link SQLCipher here.)
 */
#include <stdint.h>
#include <stdlib.h>
#include "sqlite3.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  sqlite3 *db = NULL;
  if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
    sqlite3_close(db);
    return 0;
  }
  /* A minimal CRR: crsql_changes only accepts rows for a crr-ified table. */
  sqlite3_exec(db, "CREATE TABLE foo(id INTEGER PRIMARY KEY NOT NULL, a TEXT);",
               NULL, NULL, NULL);
  sqlite3_exec(db, "SELECT crsql_as_crr('foo');", NULL, NULL, NULL);

  sqlite3_stmt *st = NULL;
  static const char *kInsert =
      "INSERT INTO crsql_changes "
      "(\"table\",\"pk\",\"cid\",\"val\",\"col_version\",\"db_version\","
      "\"site_id\",\"cl\",\"seq\") "
      "VALUES ('foo',?1,'a','x',1,1,zeroblob(16),1,0)";
  if (sqlite3_prepare_v2(db, kInsert, -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_blob(st, 1, data, (int)size, SQLITE_STATIC);
    sqlite3_step(st); /* return code ignored: a rejection is the CORRECT path */
    sqlite3_finalize(st);
  }
  sqlite3_exec(db, "SELECT crsql_finalize();", NULL, NULL, NULL);
  sqlite3_close(db);
  return 0;
}
