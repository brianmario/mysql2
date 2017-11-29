#ifndef MYSQL2_CLIENT_H
#define MYSQL2_CLIENT_H

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
void rb_mysql_set_server_query_flags(MYSQL *client, VALUE result);

#define GET_CLIENT(self) \
  mysql_client_wrapper *wrapper; \
  Data_Get_Struct(self, mysql_client_wrapper, wrapper);

void init_mysql2_client(void);
void decr_mysql2_client(mysql_client_wrapper *wrapper);

#endif
