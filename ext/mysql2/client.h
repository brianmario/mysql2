#ifndef MYSQL2_CLIENT_H
#define MYSQL2_CLIENT_H

/* Whether the connection is in the middle of a protocol exchange that a
 * concurrent mysql_stmt_close() would corrupt. QUERYING covers the window
 * from sending a command through reading/storing its result; STREAMING
 * additionally covers the whole lifetime of an open server-side cursor,
 * since rows are pulled one at a time by later, separate Ruby calls. */
typedef enum {
  MYSQL2_CLIENT_IDLE = 0,
  MYSQL2_CLIENT_QUERYING,
  MYSQL2_CLIENT_STREAMING
} mysql2_client_state_t;

/* A MYSQL_STMT handle whose Ruby wrapper was freed while the connection
 * was not idle. Populated only from a statement's dfree callback, which
 * may run during a GC sweep -- so this list, and the code that pushes to
 * it, must never touch a Ruby VALUE or call back into the VM. The pointer
 * stored in wrapper_key is never dereferenced; it exists only so the
 * reap pass (which does run in ordinary VM context) can find and remove
 * the matching entry from prepared_statements. */
typedef struct mysql2_pending_stmt_close {
  MYSQL_STMT *stmt;
  uintptr_t wrapper_key;
  struct mysql2_pending_stmt_close *next;
} mysql2_pending_stmt_close;

typedef struct {
  VALUE encoding;
  VALUE active_fiber; /* rb_fiber_current() or Qnil */
  VALUE prepared_statements;
  long server_version;
  int reconnect_enabled;
  unsigned int connect_timeout;
  int active;
  int automatic_close;
  int initialized;
  int refcount;
  int closed;
  uint64_t affected_rows;
  MYSQL *client;
  mysql2_client_state_t state;
  mysql2_pending_stmt_close *pending_stmt_closes;
  unsigned long pending_stmt_close_count; /* O(1) mirror of the list above, for Client#pending_prepared_statement_closes */
} mysql_client_wrapper;

void rb_mysql_set_server_query_flags(MYSQL *client, VALUE result);

extern const rb_data_type_t rb_mysql_client_type;

#ifdef NEW_TYPEDDATA_WRAPPER
#define GET_CLIENT(self) \
  mysql_client_wrapper *wrapper; \
  TypedData_Get_Struct(self, mysql_client_wrapper, &rb_mysql_client_type, wrapper);
#else
#define GET_CLIENT(self) \
  mysql_client_wrapper *wrapper; \
  Data_Get_Struct(self, mysql_client_wrapper, wrapper);
#endif

void init_mysql2_client(void);
void decr_mysql2_client(mysql_client_wrapper *wrapper);

/* Safe to call from a dfree callback (GC sweep context): only touches C
 * memory owned by wrapper, never the Ruby VM. */
void mysql2_enqueue_pending_stmt_close(mysql_client_wrapper *wrapper, MYSQL_STMT *stmt, uintptr_t wrapper_key);

/* Must only be called from ordinary Ruby-level code (has the GVL, not
 * inside a GC sweep): closes queued statements and prunes
 * prepared_statements. Call before starting a new command, and right
 * after a streaming result finishes or is abandoned. */
void mysql2_reap_pending_stmt_closes(mysql_client_wrapper *wrapper);

/* Also ordinary-Ruby-level-only, like the reap above, but never attempts
 * mysql_stmt_close(): for Client#close, where the connection is about to
 * go away regardless, so there is no point notifying the server for each
 * statement individually -- mysql_close() (or the server's own session
 * teardown) already releases all of them. Still clears the C list and
 * prunes prepared_statements, since this runs in ordinary Ruby context and
 * can safely touch both. */
void mysql2_drop_pending_stmt_closes(mysql_client_wrapper *wrapper);

#endif
