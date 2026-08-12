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

/* A result set (MYSQL_RES and/or the row-fetch state of a MYSQL_STMT) whose
 * Ruby Result wrapper was freed while it was an abandoned, not-fully-drained
 * stream (mysql_use_result(), or a server-side cursor opened for a streaming
 * prepared statement). Actually releasing either one can require reading and
 * discarding whatever rows are still queued on the wire
 * (mysql_free_result()'s flush_use_result, or mysql_stmt_free_result()
 * discarding an open cursor's outstanding rows) -- blocking network I/O,
 * unsafe from a dfree callback that may run during a GC sweep for the same
 * reason as mysql2_pending_stmt_close above. Populated only from Result's
 * dfree callback, so must never touch a Ruby VALUE or call back into the
 * VM. */
typedef struct mysql2_pending_result_free {
  MYSQL_RES *result; /* NULL if nothing to free at this level */
  MYSQL_STMT *stmt;  /* NULL for plain (non-prepared) results */
  struct mysql2_pending_result_free *next;
} mysql2_pending_result_free;

typedef struct {
  VALUE encoding;
  VALUE active_fiber; /* rb_fiber_current() or Qnil */
  VALUE prepared_statements;
  /* The Mysql2::Result for the currently open streaming cursor (state ==
   * MYSQL2_CLIENT_STREAMING), or Qnil. pending_result_frees only ever gets
   * populated once GC has actually collected an abandoned streaming
   * Result; if the app abandons a stream and issues another command
   * before that happens, this is what lets mysql2_abandon_active_stream
   * find and force-drain the still-live object right now, instead of
   * sending the new command while the server still thinks a cursor is
   * open. */
  VALUE active_streaming_result;
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
  mysql2_pending_result_free *pending_result_frees;
  unsigned long pending_result_free_count;
} mysql_client_wrapper;

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

/* Raises a Mysql2::Error built from the client's current mysql_error()/
 * mysql_errno()/mysql_sqlstate() -- the only correct way to surface a
 * server/connection error with error_number and sql_state populated.
 * Never construct a Mysql2::Error via a plain rb_raise(cMysql2Error, ...)
 * instead of this: doing so silently leaves error_number and sql_state nil. */
VALUE rb_raise_mysql2_error(mysql_client_wrapper *wrapper);

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

/* Safe to call from a dfree callback (GC sweep context): only touches C
 * memory owned by wrapper, never the Ruby VM, never blocks on I/O. */
void mysql2_enqueue_pending_result_free(mysql_client_wrapper *wrapper, MYSQL_RES *result, MYSQL_STMT *stmt);

/* Must only be called from ordinary Ruby-level code (has the GVL, not
 * inside a GC sweep): actually frees queued result sets, which may block on
 * network I/O to discard unread rows. Call before starting a new command on
 * the connection, and right after a streaming result finishes or is
 * abandoned. Must be called before mysql2_reap_pending_stmt_closes at any
 * shared call site: a statement's outstanding result must be freed before
 * the statement handle itself is closed. */
void mysql2_reap_pending_result_frees(mysql_client_wrapper *wrapper);

/* Unlike mysql2_drop_pending_stmt_closes, there is no drop-only counterpart
 * for result frees: mysql_close() has no side effect that reclaims a
 * MYSQL_RES's client-side row buffers (it only releases the server's
 * prepared-statement handles), so skipping the free would leak that memory
 * for the rest of the process. Client#close therefore calls
 * mysql2_reap_pending_result_frees directly instead -- it's ordinary
 * Ruby-level code, so the network I/O that may involve is fine there, same
 * as at any other safe point. Only the dfree-reachable teardown in
 * decr_mysql2_client (client.c) has no such option and must drop instead. */

/* If the connection is still STREAMING because the previous streaming
 * Result was abandoned (caller broke out of #each, or raised, without
 * exhausting the cursor) rather than naturally exhausted or already
 * collected by GC, force-drain and free it now, before a new command goes
 * out. Ordinary-Ruby-level-only, like the reap functions above -- it calls
 * into result.c and may hit the socket. No-op if there's no live Result to
 * drain (already handled, or already queued via
 * mysql2_enqueue_pending_result_free for mysql2_reap_pending_result_frees
 * to pick up). Call right before sending any new command (query, prepare,
 * execute, ping, statement close). */
void mysql2_abandon_active_stream(mysql_client_wrapper *wrapper);

#endif
