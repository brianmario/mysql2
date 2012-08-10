#ifndef MYSQL2_CLIENT_H
#define MYSQL2_CLIENT_H

/*
 * partial emulation of the 1.9 rb_thread_blocking_region under 1.8,
 * this is enough for dealing with blocking I/O functions in the
 * presence of threads.
 */
#ifndef HAVE_RB_THREAD_BLOCKING_REGION

#include <rubysig.h>
#define RUBY_UBF_IO ((rb_unblock_function_t *)-1)
typedef void rb_unblock_function_t(void *);
typedef VALUE rb_blocking_function_t(void *);
static VALUE
rb_thread_blocking_region(
  rb_blocking_function_t *func, void *data1,
  RB_MYSQL_UNUSED rb_unblock_function_t *ubf,
  RB_MYSQL_UNUSED void *data2)
{
  VALUE rv;

  TRAP_BEG;
  rv = func(data1);
  TRAP_END;

  return rv;
}

#endif /* ! HAVE_RB_THREAD_BLOCKING_REGION */

void init_mysql2_client();

typedef struct {
  VALUE encoding;
  VALUE active_thread; /* rb_thread_current() or Qnil */
  int reconnect_enabled;
  int active;
  int connected;
  int initialized;
  MYSQL *client;
} mysql_client_wrapper;

#define REQUIRE_INITIALIZED(wrapper) \
  if (!wrapper->initialized) { \
    rb_raise(cMysql2Error, "MySQL client is not initialized"); \
  }

#define REQUIRE_CONNECTED(wrapper) \
  REQUIRE_INITIALIZED(wrapper) \
  if (!wrapper->connected && !wrapper->reconnect_enabled) { \
    rb_raise(cMysql2Error, "closed MySQL connection"); \
  }

#define REQUIRE_NOT_CONNECTED(wrapper) \
  REQUIRE_INITIALIZED(wrapper) \
  if (wrapper->connected) { \
    rb_raise(cMysql2Error, "MySQL connection is already open"); \
  }

#define GET_CLIENT(self) \
  mysql_client_wrapper *wrapper; \
  Data_Get_Struct(self, mysql_client_wrapper, wrapper)

void rb_mysql_client_set_active_thread(VALUE self);

#define MARK_CONN_INACTIVE(conn) do {\
    GET_CLIENT(conn); \
    wrapper->active_thread = Qnil; \
  } while(0)

#endif
