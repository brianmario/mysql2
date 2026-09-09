#include "mysql2_ext.h"
#include <assert.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/resource.h>

static int fail_malloc, fail_strdup, interrupt_open, interrupt_read;
static int fail_open, fail_read, return_eof, closed_count, open_count, read_count;
static void *test_malloc(size_t size) {
  void *ptr;
  if (fail_malloc) { errno = ENOMEM; return NULL; }
  ptr = malloc(size);
  if (ptr) memset(ptr, 0, size);
  return ptr;
}
static char *test_strdup(const char *str) {
  if (fail_strdup) { errno = ENOMEM; return NULL; }
  return strdup(str);
}
static int test_open(const char *filename, int flags) {
  (void)filename; (void)flags;
  open_count++;
  if (interrupt_open > 0) { interrupt_open--; errno = EINTR; return -1; }
  if (fail_open) { errno = ENOENT; return -1; }
  return 42;
}
static ssize_t test_read(int fd, void *buf, size_t length) {
  assert(fd == 42);
  assert(length >= 3);
  read_count++;
  if (interrupt_read > 0) { interrupt_read--; errno = EINTR; return -1; }
  if (fail_read) { errno = EIO; return -1; }
  if (return_eof) return 0;
  memcpy(buf, "abc", 3);
  return 3;
}
static int test_close(int fd) { assert(fd == 42); closed_count++; return 0; }

#define malloc test_malloc
#define strdup test_strdup
#define open test_open
#define read test_read
#define close test_close
#ifndef MYSQL2_INFILE_SOURCE
#define MYSQL2_INFILE_SOURCE "../../../ext/mysql2/infile.c"
#endif
#include MYSQL2_INFILE_SOURCE
#undef malloc
#undef strdup
#undef open
#undef read
#undef close

int main(int argc, char **argv) {
  void *ptr = (void *)1;
  char buffer[128];
  int rc, interrupted = 0;
  struct rlimit core_limit = {0, 0};
  setrlimit(RLIMIT_CORE, &core_limit);
  assert(argc == 2);
  if (!strcmp(argv[1], "malloc")) {
    fail_malloc = 1;
    assert(mysql2_local_infile_init(&ptr, "fixture", NULL) == 1);
    assert(ptr == NULL);
    assert(mysql2_local_infile_error(ptr, buffer, sizeof(buffer)) == CR_OUT_OF_MEMORY);
    mysql2_local_infile_end(ptr);
    assert(closed_count == 0);
  } else if (!strcmp(argv[1], "strdup")) {
    fail_strdup = 1;
    assert(mysql2_local_infile_init(&ptr, "fixture", NULL) == 1);
    assert(mysql2_local_infile_error(ptr, buffer, sizeof(buffer)) == CR_UNKNOWN_ERROR);
    mysql2_local_infile_end(ptr);
    assert(closed_count == 0);
  } else if (!strcmp(argv[1], "open_error") || !strcmp(argv[1], "open_eintr")) {
    /* An interrupted open is reported like any other failure, once: it is
     * how a cancelled transfer stops. */
    fail_open = !strcmp(argv[1], "open_error");
    interrupt_open = !strcmp(argv[1], "open_eintr") ? 1 : 0;
    assert(mysql2_local_infile_init(&ptr, "fixture", NULL) == 1);
    assert(open_count == 1);
    assert(mysql2_local_infile_error(ptr, buffer, sizeof(buffer)) == CR_UNKNOWN_ERROR);
    assert(strstr(buffer, "fixture") != NULL);
    mysql2_local_infile_end(ptr);
    assert(closed_count == 0);
  } else {
    assert(mysql2_local_infile_init(&ptr, "fixture", NULL) == 0);
    assert(open_count == 1);
    interrupted = !strcmp(argv[1], "read_eintr");
    interrupt_read = interrupted;
    fail_read = !strcmp(argv[1], "read_error");
    return_eof = !strcmp(argv[1], "eof");
    rc = mysql2_local_infile_read(ptr, buffer, sizeof(buffer));
    if (fail_read || interrupted) {
      /* An interrupted read is reported like an I/O error, once. */
      assert(rc == -1);
      assert(read_count == 1);
      assert(mysql2_local_infile_error(ptr, buffer, sizeof(buffer)) == CR_UNKNOWN_ERROR);
      assert(strstr(buffer, "fixture") != NULL);
    } else if (return_eof) {
      assert(rc == 0);
      assert(read_count == 1);
    } else {
      assert(rc == 3);
      assert(read_count == 1);
      assert(!memcmp(buffer, "abc", 3));
    }
    mysql2_local_infile_end(ptr);
    assert(closed_count == 1);
  }
  puts("passed");
  return 0;
}
