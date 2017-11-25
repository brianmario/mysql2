#ifndef MYSQL2_CLIENT_H
#define MYSQL2_CLIENT_H

#ifndef HAVE_RB_THREAD_CALL_WITHOUT_GVL
/* emulate rb_thread_call_without_gvl with rb_thread_blocking_region */
#define rb_thread_call_without_gvl(func, data1, ubf, data2) \
  rb_thread_blocking_region((rb_blocking_function_t *)func, data1, ubf, data2)
#endif /* ! HAVE_RB_THREAD_CALL_WITHOUT_GVL */

typedef struct {
  VALUE encoding;
  VALUE active_thread; /* rb_thread_current() or Qnil */
  long server_version;
  int reconnect_enabled;
  unsigned int connect_timeout;
  int active;
  int automatic_close;
  int initialized;
  int refcount;
  int closed;
  MYSQL *client;
} mysql_client_wrapper;

void rb_mysql_client_set_active_thread(VALUE self);

#define GET_CLIENT(self) \
  mysql_client_wrapper *wrapper; \
  Data_Get_Struct(self, mysql_client_wrapper, wrapper);

void init_mysql2_client(void);
void decr_mysql2_client(mysql_client_wrapper *wrapper);

#endif
