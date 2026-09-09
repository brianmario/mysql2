/* macOS interposition fixture: count actual native handle allocations/frees. */
#include <mysql.h>

static unsigned long created, closed;

static MYSQL_STMT *counted_init(MYSQL *mysql) {
  MYSQL_STMT *stmt = mysql_stmt_init(mysql);
  if (stmt) created++;
  return stmt;
}

static __typeof__(mysql_stmt_close((MYSQL_STMT *)0)) counted_close(MYSQL_STMT *stmt) {
  if (stmt) closed++;
  return mysql_stmt_close(stmt);
}

unsigned long mysql2_test_live_statements(void) {
  return created - closed;
}

__attribute__((used)) static const struct {
  const void *replacement;
  const void *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
  { (const void *)counted_init, (const void *)mysql_stmt_init },
  { (const void *)counted_close, (const void *)mysql_stmt_close }
};
