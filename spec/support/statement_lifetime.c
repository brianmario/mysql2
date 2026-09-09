/* macOS interposition fixture: append one line per native statement handle
 * init and close to the file named by MYSQL2_STATEMENT_LIFETIME_REPORT. The
 * child appends its own "checkpoint" line, so the parent can balance the two
 * counts at that exact point in the child's execution. */
#include <mysql.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int report_fd = -1;

/* Runs once, before main(), on the single startup thread. */
__attribute__((constructor)) static void open_report(void) {
  static const char failure[] = "statement_lifetime: cannot open MYSQL2_STATEMENT_LIFETIME_REPORT\n";
  const char *path = getenv("MYSQL2_STATEMENT_LIFETIME_REPORT");

  if (!path) return;
  report_fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
  if (report_fd < 0) (void)write(STDERR_FILENO, failure, sizeof(failure) - 1);
}

/* write(2) only: mysql_stmt_close can be reached from a GC callback, which
 * must not re-enter the Ruby VM, and buffered stdio would leave records
 * unwritten if the process ended abruptly. A record that cannot be written
 * is reported on stderr so the parent sees a logging failure rather than a
 * lifecycle imbalance. */
static void log_event(const char *line) {
  static const char failure[] = "statement_lifetime: cannot write to the report\n";
  size_t remaining = strlen(line);

  if (report_fd < 0) return;
  while (remaining > 0) {
    ssize_t written = write(report_fd, line, remaining);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) {
      (void)write(STDERR_FILENO, failure, sizeof(failure) - 1);
      return;
    }
    line += written;
    remaining -= (size_t)written;
  }
}

static MYSQL_STMT *counted_init(MYSQL *mysql) {
  MYSQL_STMT *stmt = mysql_stmt_init(mysql);
  if (stmt) log_event("init\n");
  return stmt;
}

static __typeof__(mysql_stmt_close((MYSQL_STMT *)0)) counted_close(MYSQL_STMT *stmt) {
  if (stmt) log_event("close\n");
  return mysql_stmt_close(stmt);
}

__attribute__((used)) static const struct {
  const void *replacement;
  const void *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
  { (const void *)counted_init, (const void *)mysql_stmt_init },
  { (const void *)counted_close, (const void *)mysql_stmt_close }
};
