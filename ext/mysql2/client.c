#include <mysql2_ext.h>

#include <stdbool.h>
#include <time.h>
#include <errno.h>
#ifndef _WIN32
#include <sys/types.h>
#include <sys/socket.h>
#endif
#ifndef _MSC_VER
#include <unistd.h>
#endif
#include <fcntl.h>
#include "wait_for_single_fd.h"

#include "mysql_enc_name_to_ruby.h"

VALUE cMysql2Client;
extern VALUE mMysql2, cMysql2Error, cMysql2TimeoutError;
static VALUE sym_id, sym_version, sym_header_version, sym_async, sym_symbolize_keys, sym_as, sym_array, sym_stream;
static ID intern_brackets, intern_merge, intern_merge_bang, intern_new_with_args,
  intern_current_query_options, intern_read_timeout, intern_values;

#define REQUIRE_INITIALIZED(wrapper) \
  if (!wrapper->initialized) { \
    rb_raise(cMysql2Error, "MySQL client is not initialized"); \
  }

#if defined(HAVE_MYSQL_NET_VIO) || defined(HAVE_ST_NET_VIO)
  #define CONNECTED(wrapper) (wrapper->client->net.vio != NULL && wrapper->client->net.fd != -1)
#elif defined(HAVE_MYSQL_NET_PVIO) || defined(HAVE_ST_NET_PVIO)
  #define CONNECTED(wrapper) (wrapper->client->net.pvio != NULL && wrapper->client->net.fd != -1)
#endif

#define REQUIRE_CONNECTED(wrapper) \
  REQUIRE_INITIALIZED(wrapper) \
  if (!CONNECTED(wrapper) && !wrapper->reconnect_enabled) { \
    rb_raise(cMysql2Error, "MySQL client is not connected"); \
  }

#define REQUIRE_NOT_CONNECTED(wrapper) \
  REQUIRE_INITIALIZED(wrapper) \
  if (CONNECTED(wrapper)) { \
    rb_raise(cMysql2Error, "MySQL connection is already open"); \
  }

/*
 * compatibility with mysql-connector-c, where LIBMYSQL_VERSION is the correct
 * variable to use, but MYSQL_SERVER_VERSION gives the correct numbers when
 * linking against the server itself
 *
 * MariaDB exposes its client version independently to the server version as
 * MARIADB_PACKAGE_VERSION.
 */
#if defined(MARIADB_PACKAGE_VERSION)
  #define MYSQL_LINK_VERSION MARIADB_PACKAGE_VERSION
#elif defined(LIBMYSQL_VERSION)
  #define MYSQL_LINK_VERSION LIBMYSQL_VERSION
#else
  #define MYSQL_LINK_VERSION MYSQL_SERVER_VERSION
#endif

/*
 * mariadb-connector-c defines CLIENT_SESSION_TRACKING and SESSION_TRACK_TRANSACTION_TYPE
 * while mysql-connector-c defines CLIENT_SESSION_TRACK and SESSION_TRACK_TRANSACTION_STATE
 * This is a hack to take care of both clients.
 */
#if defined(CLIENT_SESSION_TRACK)
#elif defined(CLIENT_SESSION_TRACKING)
  #define CLIENT_SESSION_TRACK CLIENT_SESSION_TRACKING
  #define SESSION_TRACK_TRANSACTION_STATE SESSION_TRACK_TRANSACTION_TYPE
#endif

/*
 * compatibility with mysql-connector-c 6.1.x, MySQL 5.7.3 - 5.7.10 & with MariaDB 10.x and later.
 */
#ifdef HAVE_CONST_MYSQL_OPT_SSL_VERIFY_SERVER_CERT
  #define SSL_MODE_VERIFY_IDENTITY 5
  /* MYSQL_OPT_SSL_VERIFY_SERVER_CERT is the only verification this client
   * library offers -- it checks the CA and the hostname together, with no
   * way to ask for one without the other. SSL_MODE_VERIFY_CA maps to the
   * same option: full verification is the closest honest behavior available,
   * and strictly safer than the alternative of accepting any CA silently. */
  #define SSL_MODE_VERIFY_CA 4
  #define HAVE_CONST_SSL_MODE_VERIFY_IDENTITY
  #define HAVE_CONST_SSL_MODE_VERIFY_CA
#endif
#ifdef HAVE_CONST_MYSQL_OPT_SSL_ENFORCE
  #define SSL_MODE_DISABLED 1
  #define SSL_MODE_REQUIRED 3
  #define HAVE_CONST_SSL_MODE_DISABLED
  #define HAVE_CONST_SSL_MODE_REQUIRED
#endif

/*
 * used to pass all arguments to mysql_real_connect while inside
 * rb_thread_call_without_gvl
 */
struct nogvl_connect_args {
  MYSQL *mysql;
  const char *host;
  const char *user;
  const char *passwd;
  const char *db;
  unsigned int port;
  const char *unix_socket;
  unsigned long client_flag;
};

/*
 * used to pass all arguments to mysql_send_query while inside
 * rb_thread_call_without_gvl
 */
/* Shared by nogvl_send_query_args and async_query_args below: passed as its
 * own rb_ensure data argument (independent of the struct it lives in) so
 * a single trampoline can clean up after either. completed is set once the
 * owning call finishes normally, which lets that trampoline tell a normal
 * completion apart from a Thread#exit-style unwind. */
struct query_completion {
  mysql_client_wrapper *wrapper;
  int completed;
};

struct nogvl_send_query_args {
  MYSQL *mysql;
  VALUE sql;
  const char *sql_ptr;
  long sql_len;
  struct query_completion completion;
};

/*
 * used to pass all arguments to mysql_select_db while inside
 * rb_thread_call_without_gvl
 */
struct nogvl_select_db_args {
  MYSQL *mysql;
  char *db;
};

static VALUE rb_set_ssl_mode_option(VALUE self, VALUE setting) {
  unsigned long version = mysql_get_client_version();
  const char *version_str = mysql_get_client_info();

  /* Warn about versions that are known to be incomplete; these are pretty
   * ancient, we want people to upgrade if they need SSL/TLS to work
   *
   * MySQL 5.x before 5.6.30 -- ssl_mode introduced but not fully working until 5.6.36)
   * MySQL 5.7 before 5.7.3 -- ssl_mode introduced but not fully working until 5.7.11)
   */
  if ((version >= 50000 && version < 50630) || (version >= 50700 && version < 50703)) {
    rb_warn("Your mysql client library version %s does not support setting ssl_mode; full support comes with 5.6.36+, 5.7.11+, 8.0+", version_str);
    return Qnil;
  }

  /* For these versions, map from the options we're exposing to Ruby to the constant available:
   *   ssl_mode: :verify_identity to MYSQL_OPT_SSL_VERIFY_SERVER_CERT = 1
   *   ssl_mode: :required to MYSQL_OPT_SSL_ENFORCE = 1
   *   ssl_mode: :disabled to MYSQL_OPT_SSL_ENFORCE = 0
   */
#if defined(HAVE_CONST_MYSQL_OPT_SSL_VERIFY_SERVER_CERT) || defined(HAVE_CONST_MYSQL_OPT_SSL_ENFORCE)
  GET_CLIENT(self);
  int val = NUM2INT(setting);

  /* Expected code path for MariaDB 10.x and MariaDB Connector/C 3.x
   * Workaround code path for MySQL 5.7.3 - 5.7.10 and MySQL Connector/C 6.1.3 - 6.1.x
   */
  if (version >= 100000                         // MariaDB (all versions numbered 10.x)
    || (version >= 30000 && version < 40000)    // MariaDB Connector/C (all versions numbered 3.x)
    || (version >= 50703 && version < 50711)    // Workaround for MySQL 5.7.3 - 5.7.10
    || (version >= 60103 && version < 60200)) { // Workaround for MySQL Connector/C 6.1.3 - 6.1.x
#ifdef HAVE_CONST_MYSQL_OPT_SSL_VERIFY_SERVER_CERT
    /* This client library has no CA-only verification mode -- verify_ca
     * gets the same full verification as verify_identity, since that's the
     * only real verification MYSQL_OPT_SSL_VERIFY_SERVER_CERT offers. */
    if (val == SSL_MODE_VERIFY_IDENTITY || val == SSL_MODE_VERIFY_CA) {
      my_bool b = 1;
      int result = mysql_options(wrapper->client, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &b);
      return INT2NUM(result);
    }
#endif
#ifdef HAVE_CONST_MYSQL_OPT_SSL_ENFORCE
    if (val == SSL_MODE_DISABLED || val == SSL_MODE_REQUIRED) {
      my_bool b = (val == SSL_MODE_REQUIRED);
      int result = mysql_options(wrapper->client, MYSQL_OPT_SSL_ENFORCE, &b);
      return INT2NUM(result);
    }
#endif
    rb_warn("Your mysql client library version %s does not support ssl_mode %d", version_str, val);
    return Qnil;
  } else {
    rb_warn("Your mysql client library version %s does not support ssl_mode as expected", version_str);
    return Qnil;
  }
#endif

  /* For other versions -- known to be MySQL 5.6.36+, 5.7.11+, 8.0+
   * pass the value of the argument to MYSQL_OPT_SSL_MODE -- note the code
   * mapping from atoms / constants is in the MySQL::Client Ruby class
   */
#ifdef FULL_SSL_MODE_SUPPORT
  GET_CLIENT(self);
  int val = NUM2INT(setting);

  if (val != SSL_MODE_DISABLED && val != SSL_MODE_PREFERRED && val != SSL_MODE_REQUIRED && val != SSL_MODE_VERIFY_CA && val != SSL_MODE_VERIFY_IDENTITY) {
    rb_raise(cMysql2Error, "ssl_mode= takes DISABLED, PREFERRED, REQUIRED, VERIFY_CA, VERIFY_IDENTITY, you passed: %d", val );
  }
  int result = mysql_options(wrapper->client, MYSQL_OPT_SSL_MODE, &val);

  return INT2NUM(result);
#endif

  // Warn if we get this far
#ifdef NO_SSL_MODE_SUPPORT
  rb_warn("Your mysql client library does not support setting ssl_mode");
  return Qnil;
#endif
}

/*
 * non-blocking mysql_*() functions that we won't be wrapping since
 * they do not appear to hit the network nor issue any interruptible
 * or blocking system calls.
 *
 * - mysql_affected_rows()
 * - mysql_error()
 * - mysql_fetch_fields()
 * - mysql_fetch_lengths() - calls cli_fetch_lengths or emb_fetch_lengths
 * - mysql_field_count()
 * - mysql_get_client_info()
 * - mysql_get_client_version()
 * - mysql_get_server_info()
 * - mysql_get_server_version()
 * - mysql_insert_id()
 * - mysql_num_fields()
 * - mysql_num_rows()
 * - mysql_options()
 * - mysql_real_escape_string()
 * - mysql_ssl_set()
 */

static void rb_mysql_client_mark(void * wrapper) {
  mysql_client_wrapper * w = wrapper;
  if (w) {
    rb_gc_mark_movable(w->encoding);
    rb_gc_mark_movable(w->active_fiber);
    rb_gc_mark_movable(w->prepared_statements);
    rb_gc_mark_movable(w->active_streaming_result);
  }
}

/* this is called during GC */
static void rb_mysql_client_free(void *ptr) {
  mysql_client_wrapper *wrapper = ptr;
  decr_mysql2_client(wrapper);
}

static size_t rb_mysql_client_memsize(const void * wrapper) {
  const mysql_client_wrapper * w = wrapper;
  return sizeof(*w);
}

static void rb_mysql_client_compact(void * wrapper) {
  mysql_client_wrapper * w = wrapper;
  if (w) {
    rb_mysql2_gc_location(w->encoding);
    rb_mysql2_gc_location(w->active_fiber);
    rb_mysql2_gc_location(w->prepared_statements);
    rb_mysql2_gc_location(w->active_streaming_result);
  }
}

const rb_data_type_t rb_mysql_client_type = {
  "rb_mysql_client",
  {
    rb_mysql_client_mark,
    rb_mysql_client_free,
    rb_mysql_client_memsize,
#ifdef HAVE_RB_GC_MARK_MOVABLE
    rb_mysql_client_compact,
#endif
  },
  0,
  0,
#ifdef RUBY_TYPED_FREE_IMMEDIATELY
  RUBY_TYPED_FREE_IMMEDIATELY,
#endif
};

VALUE rb_raise_mysql2_error(mysql_client_wrapper *wrapper) {
  VALUE rb_error_msg = rb_str_new2(mysql_error(wrapper->client));
  VALUE rb_sql_state = rb_str_new2(mysql_sqlstate(wrapper->client));
  VALUE e;

  rb_enc_associate(rb_error_msg, rb_utf8_encoding());
  rb_enc_associate(rb_sql_state, rb_usascii_encoding());

  e = rb_funcall(cMysql2Error, intern_new_with_args, 4,
                 rb_error_msg,
                 LONG2FIX(wrapper->server_version),
                 UINT2NUM(mysql_errno(wrapper->client)),
                 rb_sql_state);
  rb_exc_raise(e);
}

static void *nogvl_init(void *ptr) {
  MYSQL *client;
  mysql_client_wrapper *wrapper = ptr;

  /* may initialize embedded server and read /etc/services off disk */
  client = mysql_init(wrapper->client);

  if (client) mysql2_set_local_infile(client, wrapper);

  return (void*)(client ? Qtrue : Qfalse);
}

static void *nogvl_connect(void *ptr) {
  struct nogvl_connect_args *args = ptr;
  MYSQL *client;

  client = mysql_real_connect(args->mysql, args->host,
                              args->user, args->passwd,
                              args->db, args->port, args->unix_socket,
                              args->client_flag);

  return (void *)(client ? Qtrue : Qfalse);
}

#ifndef _WIN32
/*
 * Redirect clientfd to /dev/null for mysql_close and SSL_close to write,
 * shutdown, and close. The hack is needed to prevent shutdown() from breaking
 * a socket that may be in use by the parent or other processes after fork.
 *
 * /dev/null is used to absorb writes; previously a dummy socket was used, but
 * it could not absorb writes and caused openssl to go into an infinite loop.
 *
 * Returns Qtrue or Qfalse (success or failure)
 *
 * Note: if this function is needed on Windows, use "nul" instead of "/dev/null"
 */
static VALUE invalidate_fd(int clientfd)
{
#ifdef O_CLOEXEC
  /* Atomically set CLOEXEC on the new FD in case another thread forks */
  int sockfd = open("/dev/null", O_RDWR | O_CLOEXEC);
#else
  /* Well we don't have O_CLOEXEC, trigger the fallback code below */
  int sockfd = -1;
#endif

  if (sockfd < 0) {
    /* Either O_CLOEXEC wasn't defined at compile time, or it was defined at
     * compile time, but isn't available at run-time. So we'll just be quick
     * about setting FD_CLOEXEC now.
     */
    int flags;
    sockfd = open("/dev/null", O_RDWR);
    flags = fcntl(sockfd, F_GETFD);
    /* Do the flags dance in case there are more defined flags in the future */
    if (flags != -1) {
      flags |= FD_CLOEXEC;
      fcntl(sockfd, F_SETFD, flags);
    }
  }

  if (sockfd < 0) {
    /* Cannot raise here, because one or both of the following may be true:
     * a) we have no GVL (in C Ruby)
     * b) are running as a GC finalizer
     */
    return Qfalse;
  }

  dup2(sockfd, clientfd);
  close(sockfd);

  return Qtrue;
}
#endif /* _WIN32 */

void mysql2_enqueue_pending_stmt_close(mysql_client_wrapper *wrapper, MYSQL_STMT *stmt, uintptr_t wrapper_key)
{
  /* Deliberately plain malloc(), not Ruby's xmalloc(): this runs from a
   * dfree callback, which can fire during a GC sweep. xmalloc() may itself
   * try to trigger a GC run on allocation failure, and doing that while a
   * GC is already in progress aborts the process with
   * "[BUG] Cannot malloc during GC" -- reproduced while testing this. */
  mysql2_pending_stmt_close *node = malloc(sizeof(mysql2_pending_stmt_close));
  if (!node) return; /* leaks the MYSQL_STMT server-side; nothing safe to do here */
  node->stmt = stmt;
  node->wrapper_key = wrapper_key;
  node->next = wrapper->pending_stmt_closes;
  wrapper->pending_stmt_closes = node;
  wrapper->pending_stmt_close_count++;
}

static void *nogvl_stmt_close_raw(void *ptr) {
  mysql_stmt_close((MYSQL_STMT *)ptr);
  return NULL;
}

void mysql2_reap_pending_stmt_closes(mysql_client_wrapper *wrapper)
{
  mysql2_pending_stmt_close *node = wrapper->pending_stmt_closes;
  wrapper->pending_stmt_closes = NULL;
  wrapper->pending_stmt_close_count = 0;

  while (node) {
    mysql2_pending_stmt_close *next = node->next;

    if (wrapper->initialized && !wrapper->closed && CONNECTED(wrapper)) {
      rb_thread_call_without_gvl(nogvl_stmt_close_raw, node->stmt, RUBY_UBF_IO, 0);
    }
    rb_hash_delete(wrapper->prepared_statements, ULL2NUM((unsigned long long)node->wrapper_key));

    free(node);
    node = next;
  }
}

/* See client.h: used by Client#close, which deliberately skips the
 * mysql_stmt_close() network round trips above -- the connection is going
 * away regardless -- but still needs the Ruby-visible bookkeeping cleared. */
void mysql2_drop_pending_stmt_closes(mysql_client_wrapper *wrapper)
{
  mysql2_pending_stmt_close *node = wrapper->pending_stmt_closes;
  wrapper->pending_stmt_closes = NULL;
  wrapper->pending_stmt_close_count = 0;

  while (node) {
    mysql2_pending_stmt_close *next = node->next;
    rb_hash_delete(wrapper->prepared_statements, ULL2NUM((unsigned long long)node->wrapper_key));
    free(node);
    node = next;
  }
}

void mysql2_enqueue_pending_result_free(mysql_client_wrapper *wrapper, MYSQL_RES *result, MYSQL_STMT *stmt)
{
  /* Deliberately plain malloc(), not Ruby's xmalloc(): see the identical
   * note on mysql2_enqueue_pending_stmt_close above. */
  mysql2_pending_result_free *node = malloc(sizeof(mysql2_pending_result_free));
  if (!node) return; /* leaks the result set's client-side memory; nothing safe to do here */
  node->result = result;
  node->stmt = stmt;
  node->next = wrapper->pending_result_frees;
  wrapper->pending_result_frees = node;
  wrapper->pending_result_free_count++;
}

static void *nogvl_stmt_free_result_raw(void *ptr) {
  mysql_stmt_free_result((MYSQL_STMT *)ptr);
  return NULL;
}

static void *nogvl_free_result_raw(void *ptr) {
  mysql_free_result((MYSQL_RES *)ptr);
  return NULL;
}

void mysql2_reap_pending_result_frees(mysql_client_wrapper *wrapper)
{
  mysql2_pending_result_free *node = wrapper->pending_result_frees;
  wrapper->pending_result_frees = NULL;
  wrapper->pending_result_free_count = 0;

  while (node) {
    mysql2_pending_result_free *next = node->next;

    if (wrapper->initialized && !wrapper->closed && CONNECTED(wrapper)) {
      /* Order matters: free the statement's outstanding result (which may
       * discard unread cursor rows) before anything else touches that
       * statement handle again. */
      if (node->stmt) {
        rb_thread_call_without_gvl(nogvl_stmt_free_result_raw, node->stmt, RUBY_UBF_IO, 0);
      }
      if (node->result) {
        rb_thread_call_without_gvl(nogvl_free_result_raw, node->result, RUBY_UBF_IO, 0);
      }
    }

    free(node);
    node = next;
  }
}

/* See client.h. */
void mysql2_abandon_active_stream(mysql_client_wrapper *wrapper)
{
  if (wrapper->state == MYSQL2_CLIENT_STREAMING && wrapper->active_streaming_result != Qnil) {
    mysql2_result_force_free(wrapper->active_streaming_result);
    wrapper->active_streaming_result = Qnil;
  }
}

static void *nogvl_close(void *ptr) {
  mysql_client_wrapper *wrapper = ptr;

  if (wrapper->initialized && !wrapper->closed) {
    mysql_close(wrapper->client);
    wrapper->closed = 1;
    wrapper->reconnect_enabled = 0;
    wrapper->active_fiber = Qnil;
  }

  return NULL;
}

void decr_mysql2_client(mysql_client_wrapper *wrapper)
{
  if (!wrapper)
    return;

  wrapper->refcount--;
  if (wrapper->refcount > 0)
    return;

#ifndef _WIN32
  /* TODO: add an option to control close-across-forks because some users have
   * complained about log noise on the server side and were not running code
   * that expected to inherit a connection to a child process.
   */
  if (CONNECTED(wrapper) && !wrapper->automatic_close) {
    /* The client is being garbage collected while connected. Prevent
     * mysql_close() from sending a mysql-QUIT or from calling shutdown() on
     * the socket by invalidating it. invalidate_fd() will drop this
     * process's reference to the socket only, while a QUIT or shutdown()
     * would render the underlying connection unusable, interrupting other
     * processes which share this object across a fork().
     */
    if (invalidate_fd(wrapper->client->net.fd) == Qfalse) {
      fprintf(stderr, "[WARN] mysql2 failed to invalidate FD safely\n");
      close(wrapper->client->net.fd);
    }
    wrapper->client->net.fd = -1;
  }
#endif

  /* Any statements queued for a deferred close are moot: mysql_close()
   * below already releases all of this session's prepared statements on
   * the server, and this may itself be running during a GC sweep, so we
   * must not touch prepared_statements (a Ruby Hash) or attempt any more
   * network I/O here -- just drop the list. */
  {
    mysql2_pending_stmt_close *node = wrapper->pending_stmt_closes;
    while (node) {
      mysql2_pending_stmt_close *next = node->next;
      free(node); /* plain free(): this too can run during a GC sweep */
      node = next;
    }
    wrapper->pending_stmt_closes = NULL;
    wrapper->pending_stmt_close_count = 0;
  }

  /* Same reasoning for any not-yet-drained result sets: mysql_close() below
   * is about to invalidate the connection those MYSQL_RES/MYSQL_STMT
   * pointers belong to, and this may itself be running during a GC sweep,
   * so no network I/O and no VM calls -- just drop the list. This does leak
   * the client-side MYSQL_RES memory, same tradeoff already accepted above
   * for statement handles -- but only here, where we have no other choice.
   * The ordinary-Ruby-level Client#close path below does not take this
   * shortcut: see mysql2_reap_pending_result_frees at that call site. */
  {
    mysql2_pending_result_free *node = wrapper->pending_result_frees;
    while (node) {
      mysql2_pending_result_free *next = node->next;
      free(node); /* plain free(): this too can run during a GC sweep */
      node = next;
    }
    wrapper->pending_result_frees = NULL;
    wrapper->pending_result_free_count = 0;
  }

  nogvl_close(wrapper);
  xfree(wrapper->client);
  xfree(wrapper);
}

static VALUE allocate(VALUE klass) {
  VALUE obj;
  mysql_client_wrapper * wrapper;
#ifdef NEW_TYPEDDATA_WRAPPER
  obj = TypedData_Make_Struct(klass, mysql_client_wrapper, &rb_mysql_client_type, wrapper);
#else
  obj = Data_Make_Struct(klass, mysql_client_wrapper, rb_mysql_client_mark, rb_mysql_client_free, wrapper);
#endif
  wrapper->encoding = Qnil;
  wrapper->active_fiber = Qnil;
  wrapper->prepared_statements = rb_hash_new();
  wrapper->active_streaming_result = Qnil;
  wrapper->automatic_close = 1;
  wrapper->server_version = 0;
  wrapper->reconnect_enabled = 0;
  wrapper->connect_timeout = 0;
  wrapper->initialized = 0; /* will be set true after calling mysql_init */
  wrapper->closed = 1; /* will be set false after calling mysql_real_connect */
  wrapper->refcount = 1;
  wrapper->affected_rows = -1;
  wrapper->client = (MYSQL*)xmalloc(sizeof(MYSQL));
  wrapper->state = MYSQL2_CLIENT_IDLE;
  wrapper->pending_stmt_closes = NULL;
  wrapper->pending_stmt_close_count = 0;
  wrapper->pending_result_frees = NULL;
  wrapper->pending_result_free_count = 0;

  return obj;
}

static void rb_mysql_client_set_active_fiber(VALUE self, bool closing) {
  VALUE fiber_current = rb_fiber_current();
  GET_CLIENT(self);

  // see if this connection is still waiting on a result from a previous query
  if (NIL_P(wrapper->active_fiber) || (closing && !rb_fiber_alive_p(wrapper->active_fiber))) {
    // mark this connection active
    wrapper->active_fiber = fiber_current;
  } else if (wrapper->active_fiber == fiber_current) {
    if (!closing) {
      rb_raise(cMysql2Error, "This connection is still waiting for a result, try again once you have the result");
    }
  } else {
    VALUE inspect = rb_inspect(wrapper->active_fiber);
    const char *thr = StringValueCStr(inspect);

    rb_raise(cMysql2Error, "This connection is in use by: %s", thr);
  }
}

/* call-seq:
 *    Mysql2::Client.escape(string)
 *
 * Escape +string+ so that it may be used in a SQL statement.
 * Note that this escape method is not connection encoding aware.
 * If you need encoding support use Mysql2::Client#escape instead.
 */
static VALUE rb_mysql_client_escape(RB_MYSQL_UNUSED VALUE klass, VALUE str) {
  unsigned char *newStr;
  VALUE rb_str;
  unsigned long newLen, oldLen;

  Check_Type(str, T_STRING);

  oldLen = RSTRING_LEN(str);
  newStr = xmalloc(oldLen*2+1);

  newLen = mysql_escape_string((char *)newStr, RSTRING_PTR(str), oldLen);
  if (newLen == oldLen) {
    /* no need to return a new ruby string if nothing changed */
    xfree(newStr);
    return str;
  } else {
    rb_str = rb_str_new((const char*)newStr, newLen);
    rb_enc_copy(rb_str, str);
    xfree(newStr);
    return rb_str;
  }
}

static VALUE rb_mysql_client_warning_count(VALUE self) {
  unsigned int warning_count;
  GET_CLIENT(self);

  warning_count = mysql_warning_count(wrapper->client);

  return UINT2NUM(warning_count);
}

static VALUE rb_mysql_info(VALUE self) {
  const char *info;
  VALUE rb_str;
  GET_CLIENT(self);

  info = mysql_info(wrapper->client);

  if (info == NULL) {
    return Qnil;
  }

  rb_str = rb_str_new2(info);
  rb_enc_associate(rb_str, rb_utf8_encoding());

  return rb_str;
}

static VALUE rb_mysql_get_ssl_cipher(VALUE self)
{
  const char *cipher;
  VALUE rb_str;
  GET_CLIENT(self);

  cipher = mysql_get_ssl_cipher(wrapper->client);

  if (cipher == NULL) {
    return Qnil;
  }

  rb_str = rb_str_new2(cipher);
  rb_enc_associate(rb_str, rb_utf8_encoding());

  return rb_str;
}

#ifdef CLIENT_CONNECT_ATTRS
static int opt_connect_attr_add_i(VALUE key, VALUE value, VALUE arg)
{
  mysql_client_wrapper *wrapper = (mysql_client_wrapper *)arg;
  rb_encoding *enc = rb_to_encoding(wrapper->encoding);
  key = rb_str_export_to_enc(key, enc);
  value = rb_str_export_to_enc(value, enc);

  mysql_options4(wrapper->client, MYSQL_OPT_CONNECT_ATTR_ADD, StringValueCStr(key), StringValueCStr(value));
  return ST_CONTINUE;
}
#endif

static VALUE rb_mysql_connect(VALUE self, VALUE user, VALUE pass, VALUE host, VALUE port, VALUE database, VALUE socket, VALUE flags, VALUE conn_attrs, VALUE tls_sni_name) {
  struct nogvl_connect_args args;
  time_t start_time, end_time, elapsed_time, connect_timeout;
  const char *sni_hostname;
  VALUE rv;
  GET_CLIENT(self);

  args.host        = NIL_P(host)     ? NULL : StringValueCStr(host);
  args.unix_socket = NIL_P(socket)   ? NULL : StringValueCStr(socket);
  args.port        = NIL_P(port)     ? 0    : NUM2INT(port);
  args.user        = NIL_P(user)     ? NULL : StringValueCStr(user);
  args.passwd      = NIL_P(pass)     ? NULL : StringValueCStr(pass);
  args.db          = NIL_P(database) ? NULL : StringValueCStr(database);
  args.mysql       = wrapper->client;
  args.client_flag = NUM2ULONG(flags);

  sni_hostname     = NIL_P(tls_sni_name) ? NULL : StringValueCStr(tls_sni_name);

#ifdef CLIENT_CONNECT_ATTRS
  mysql_options(wrapper->client, MYSQL_OPT_CONNECT_ATTR_RESET, 0);
  rb_hash_foreach(conn_attrs, opt_connect_attr_add_i, (VALUE)wrapper);
#endif

  if (sni_hostname != NULL) {
#ifdef HAVE_CONST_MYSQL_OPT_TLS_SNI_SERVERNAME
    mysql_options(wrapper->client, MYSQL_OPT_TLS_SNI_SERVERNAME, sni_hostname);
#else
    rb_raise(cMysql2Error, "tls_sni_name is not available, you may need a newer MySQL client library (added in MySQL 8.1; not supported on MariaDB)");
#endif
  }

  if (wrapper->connect_timeout)
    time(&start_time);
  rv = (VALUE) rb_thread_call_without_gvl(nogvl_connect, &args, RUBY_UBF_IO, 0);
  if (rv == Qfalse) {
    while (rv == Qfalse && errno == EINTR) {
      if (wrapper->connect_timeout) {
        time(&end_time);
        /* avoid long connect timeout from system time changes */
        if (end_time < start_time)
          start_time = end_time;
        elapsed_time = end_time - start_time;
        /* avoid an early timeout due to time truncating milliseconds off the start time */
        if (elapsed_time > 0)
          elapsed_time--;
        if (elapsed_time >= (time_t)wrapper->connect_timeout)
          break;
        connect_timeout = wrapper->connect_timeout - elapsed_time;
        mysql_options(wrapper->client, MYSQL_OPT_CONNECT_TIMEOUT, &connect_timeout);
      }
      errno = 0;
      rv = (VALUE) rb_thread_call_without_gvl(nogvl_connect, &args, RUBY_UBF_IO, 0);
    }
    /* restore the connect timeout for reconnecting */
    if (wrapper->connect_timeout)
      mysql_options(wrapper->client, MYSQL_OPT_CONNECT_TIMEOUT, &wrapper->connect_timeout);
    if (rv == Qfalse)
      rb_raise_mysql2_error(wrapper);
  }

  /* These originate as Ruby VALUEs, but we're using their C pointers
   * directly -- keep the VALUEs live on the stack so GC can't collect them
   * while we drop the GVL to make a MySQL API call. */
  (void)RB_GC_GUARD(host);
  (void)RB_GC_GUARD(socket);
  (void)RB_GC_GUARD(user);
  (void)RB_GC_GUARD(pass);
  (void)RB_GC_GUARD(database);
  (void)RB_GC_GUARD(tls_sni_name);

  wrapper->closed = 0;
  wrapper->server_version = mysql_get_server_version(wrapper->client);
  return self;
}

/*
 * Immediately disconnect from the server; normally the garbage collector
 * will disconnect automatically when a connection is no longer needed.
 * Explicitly closing this will free up server resources sooner than waiting
 * for the garbage collector.
 *
 * @return [nil]
 */
static VALUE rb_mysql_client_close(VALUE self) {
  GET_CLIENT(self);
  rb_mysql_client_set_active_fiber(self, true);

  /* The connection is going away regardless of what mysql_close() below
   * does or doesn't send -- don't bother closing each queued statement
   * individually, just clear the bookkeeping so prepared_statements and
   * pending_prepared_statement_closes don't report stale state afterward.
   *
   * Not-yet-drained result sets are different: unlike a statement's server-
   * side handle, mysql_close() below has no side effect that reclaims a
   * MYSQL_RES's client-side row buffers, so dropping those without freeing
   * them would leak that memory for the rest of the process. This runs as
   * ordinary Ruby-level code (this method isn't reachable from a dfree
   * callback), so it's safe to actually flush and free them here, same as
   * at any other safe point -- just before the connection goes away
   * instead of before the next command. mysql2_abandon_active_stream covers
   * a stream that's abandoned but still live (not yet collected by GC),
   * which the reap alone wouldn't catch -- same reasoning as at every other
   * safe point, this one was just missing it. */
  mysql2_abandon_active_stream(wrapper);
  mysql2_reap_pending_result_frees(wrapper);
  mysql2_drop_pending_stmt_closes(wrapper);

  if (wrapper->client) {
    rb_thread_call_without_gvl(nogvl_close, wrapper, RUBY_UBF_IO, 0);
  }

  wrapper->active_fiber = Qnil;

  return Qnil;
}

/* call-seq:
 *    client.closed?
 *
 * @return [Boolean]
 */
static VALUE rb_mysql_client_closed(VALUE self) {
  GET_CLIENT(self);
  return CONNECTED(wrapper) ? Qfalse : Qtrue;
}

/*
 * mysql_send_query is unlikely to block since most queries are small
 * enough to fit in a socket buffer, but sometimes large UPDATE and
 * INSERTs will cause the process to block
 */
static void *nogvl_send_query(void *ptr) {
  struct nogvl_send_query_args *args = ptr;
  int rv;

  rv = mysql_send_query(args->mysql, args->sql_ptr, args->sql_len);

  return (void*)(rv == 0 ? Qtrue : Qfalse);
}

static VALUE do_send_query(VALUE args) {
  struct nogvl_send_query_args *query_args = (void *)args;
  mysql_client_wrapper *wrapper = query_args->completion.wrapper;
  if ((VALUE)rb_thread_call_without_gvl(nogvl_send_query, query_args, RUBY_UBF_IO, 0) == Qfalse) {
    /* An error occurred: raise it and let disconnect_query_if_incomplete
     * (this call's rb_ensure companion) do the cleanup, same as any other
     * kind of unwind out of this function. */
    rb_raise_mysql2_error(wrapper);
  }
  query_args->completion.completed = 1;
  return Qnil;
}

/*
 * even though we did rb_thread_select before calling this, a large
 * response can overflow the socket buffers and cause us to eventually
 * block while calling mysql_read_query_result
 */
static void *nogvl_read_query_result(void *ptr) {
  MYSQL * client = ptr;
  my_bool res = mysql_read_query_result(client);

  return (void *)(res == 0 ? Qtrue : Qfalse);
}

static void *nogvl_do_result(void *ptr, char use_result) {
  mysql_client_wrapper *wrapper = ptr;
  MYSQL_RES *result;

  if (use_result) {
    result = mysql_use_result(wrapper->client);
  } else {
    result = mysql_store_result(wrapper->client);
  }

  /* once our result is stored off, this connection is
     ready for another command to be issued */
  wrapper->active_fiber = Qnil;

  return result;
}

/* mysql_store_result may (unlikely) read rows off the socket */
static void *nogvl_store_result(void *ptr) {
  return nogvl_do_result(ptr, 0);
}

static void *nogvl_use_result(void *ptr) {
  return nogvl_do_result(ptr, 1);
}

/* Shared by async_result (a query's first result set) and store_result (a
 * later one, from a multi-statement batch): fetch the current result set as
 * either streamed or fully-buffered, per :stream, track it on wrapper, and
 * wrap it as a Result. */
static VALUE mysql2_fetch_result_set(VALUE self, mysql_client_wrapper *wrapper) {
  MYSQL_RES *result;
  VALUE resultObj, current, is_streaming;

  is_streaming = rb_hash_aref(rb_ivar_get(self, intern_current_query_options), sym_stream);
  if (is_streaming == Qtrue) {
    result = (MYSQL_RES *)rb_thread_call_without_gvl(nogvl_use_result, wrapper, RUBY_UBF_IO, 0);
    /* A cursor is now open; leave the connection BUSY until the Result
     * finishes (or abandons) streaming rows -- see result.c. */
    wrapper->state = MYSQL2_CLIENT_STREAMING;
  } else {
    result = (MYSQL_RES *)rb_thread_call_without_gvl(nogvl_store_result, wrapper, RUBY_UBF_IO, 0);
    /* The whole result set is buffered locally; the connection is free to
     * run another command right away. */
    wrapper->state = MYSQL2_CLIENT_IDLE;
    mysql2_reap_pending_result_frees(wrapper);
    mysql2_reap_pending_stmt_closes(wrapper);
  }

  wrapper->affected_rows = mysql_affected_rows(wrapper->client);

  if (result == NULL) {
    if (mysql_errno(wrapper->client) != 0) {
      wrapper->active_fiber = Qnil;
      wrapper->state = MYSQL2_CLIENT_IDLE;
      rb_raise_mysql2_error(wrapper);
    }
    /* no data and no error, so this result set was not a SELECT -- e.g.
     * :stream was requested for an INSERT/UPDATE. No cursor was actually
     * opened, so don't leave the connection marked STREAMING. */
    wrapper->state = MYSQL2_CLIENT_IDLE;
    return Qnil;
  }

  // Duplicate the options hash and put the copy in the Result object
  current = rb_hash_dup(rb_ivar_get(self, intern_current_query_options));
  (void)RB_GC_GUARD(current);
  Check_Type(current, T_HASH);
  resultObj = rb_mysql_result_to_obj(self, wrapper->encoding, current, result, Qnil);

  /* Track the open cursor so a later command can force-drain it if it's
   * abandoned instead of exhausted -- see mysql2_abandon_active_stream. */
  if (is_streaming == Qtrue) {
    wrapper->active_streaming_result = resultObj;
  }

  return resultObj;
}

/* call-seq:
 *    client.async_result
 *
 * Returns the result for the last async issued query.
 */
static VALUE rb_mysql_client_async_result(VALUE self) {
  GET_CLIENT(self);

  /* if we're not waiting on a result, do nothing */
  if (NIL_P(wrapper->active_fiber))
    return Qnil;

  REQUIRE_CONNECTED(wrapper);
  if ((VALUE)rb_thread_call_without_gvl(nogvl_read_query_result, wrapper->client, RUBY_UBF_IO, 0) == Qfalse) {
    /* an error occurred, mark this connection inactive */
    wrapper->active_fiber = Qnil;
    wrapper->state = MYSQL2_CLIENT_IDLE;
    rb_raise_mysql2_error(wrapper);
  }

  return mysql2_fetch_result_set(self, wrapper);
}

#ifndef _WIN32
struct async_query_args {
  int fd;
  VALUE self;
  struct query_completion completion;
};

/* Shared cleanup for an interrupted send/read/ping: none of them reached
 * their own normal completion, so the connection may be left
 * mid-protocol-exchange. */
static void invalidate_after_interrupted_query(mysql_client_wrapper *wrapper) {
  wrapper->active_fiber = Qnil;
  wrapper->state = MYSQL2_CLIENT_IDLE;

  /* Invalidate the MySQL socket to prevent further communication.
   * The GC will come along later and call mysql_close to free it.
   */
  if (CONNECTED(wrapper)) {
    if (invalidate_fd(wrapper->client->net.fd) == Qfalse) {
      fprintf(stderr, "[WARN] mysql2 failed to invalidate FD safely, closing unsafely\n");
      close(wrapper->client->net.fd);
    }
    wrapper->client->net.fd = -1;
  }
}

/* rb_rescue2 companion (do_ping): re-raises after cleanup. do_ping is a
 * single blocking call, so it has no Thread#exit window to worry about. */
static VALUE disconnect_and_raise(VALUE self, VALUE error) {
  GET_CLIENT(self);
  invalidate_after_interrupted_query(wrapper);
  rb_exc_raise(error);
}

/* rb_ensure companion (do_send_query, do_query): unlike disconnect_and_raise
 * above, this never raises -- rb_ensure runs it during any unwind, including
 * a non-exception one like Thread#exit, which rb_rescue2 can't see. Takes a
 * struct query_completion directly (passed as rb_ensure's data2, independent
 * of whatever larger struct it's embedded in) so both call sites share it. */
static VALUE disconnect_query_if_incomplete(VALUE completionval) {
  struct query_completion *completion = (void *)completionval;

  if (!completion->completed) {
    invalidate_after_interrupted_query(completion->wrapper);
  }

  return Qnil;
}

/* Waits for fd to become readable, honoring @read_timeout. Shared by
 * do_query below and next_result_nonblocking further down in this file.
 * rb_wait_for_single_fd itself releases the GVL and is interruptible
 * (Thread#raise, Timeout.timeout), unlike a raw blocking read inside
 * libmysqlclient. */
static void wait_for_readable_with_timeout(VALUE self, int fd) {
  struct timeval tv;
  struct timeval *tvp;
  long int sec;
  int retval;
  VALUE read_timeout;

  read_timeout = rb_ivar_get(self, intern_read_timeout);

  tvp = NULL;
  if (!NIL_P(read_timeout)) {
    Check_Type(read_timeout, T_FIXNUM);
    tvp = &tv;
    sec = FIX2INT(read_timeout);
    /* TODO: support partial seconds?
       also, this check is here for sanity, we also check up in Ruby */
    if (sec >= 0) {
      tvp->tv_sec = sec;
    } else {
      rb_raise(cMysql2Error, "read_timeout must be a positive integer, you passed %ld", sec);
    }
    tvp->tv_usec = 0;
  }

  retval = rb_wait_for_single_fd(fd, RB_WAITFD_IN, tvp);

  if (retval == 0) {
    rb_raise(cMysql2TimeoutError, "Timeout waiting for a response from the last query. (waited %d seconds)", FIX2INT(read_timeout));
  }
  if (retval < 0) {
    rb_sys_fail(0);
  }
}

static VALUE do_query(VALUE args) {
  struct async_query_args *async_args = (void *)args;

  wait_for_readable_with_timeout(async_args->self, async_args->fd);

  async_args->completion.completed = 1;
  return Qnil;
}
#endif

static VALUE disconnect_and_mark_inactive(VALUE self) {
  GET_CLIENT(self);

  /* Check if execution terminated while result was still being read. */
  if (!NIL_P(wrapper->active_fiber)) {
    /* async_result didn't reach its own state-management code, so this is
     * an abnormal early exit (timeout, exception). Don't leave the
     * connection stuck BUSY. */
    wrapper->state = MYSQL2_CLIENT_IDLE;
    if (CONNECTED(wrapper)) {
      /* Invalidate the MySQL socket to prevent further communication. */
#ifndef _WIN32
      if (invalidate_fd(wrapper->client->net.fd) == Qfalse) {
        rb_warn("mysql2 failed to invalidate FD safely, closing unsafely\n");
        close(wrapper->client->net.fd);
      }
#else
      close(wrapper->client->net.fd);
#endif
      wrapper->client->net.fd = -1;
    }
    /* Skip mysql client check performed before command execution. */
    wrapper->client->status = MYSQL_STATUS_READY;
    wrapper->active_fiber = Qnil;
  }

  return Qnil;
}

/* call-seq:
 *    client.abandon_results!
 *
 * When using MULTI_STATEMENTS support, calling this will throw
 * away any unprocessed results as fast as it can in order to
 * put the connection back into a state where queries can be issued
 * again.
 */
static VALUE rb_mysql_client_abandon_results(VALUE self) {
  MYSQL_RES *result;
  int ret;

  GET_CLIENT(self);

  while (mysql_more_results(wrapper->client) == 1) {
    ret = mysql_next_result(wrapper->client);
    if (ret > 0) {
      rb_raise_mysql2_error(wrapper);
    }

    result = (MYSQL_RES *)rb_thread_call_without_gvl(nogvl_store_result, wrapper, RUBY_UBF_IO, 0);

    if (result != NULL) {
      mysql_free_result(result);
    }
  }

  return Qnil;
}

/* call-seq:
 *    client.query(sql, options = {})
 *
 * Query the database with +sql+, with optional +options+.  For the possible
 * options, see default_query_options on the Mysql2::Client class.
 */
static VALUE rb_mysql_query(VALUE self, VALUE sql, VALUE current) {
#ifndef _WIN32
  struct async_query_args async_args;
#endif
  struct nogvl_send_query_args args;
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  args.mysql = wrapper->client;

  (void)RB_GC_GUARD(current);
  Check_Type(current, T_HASH);
  /* Resolve :force_encoding to an Encoding object up front: invalid values
   * raise here, before anything is written to the wire, leaving the
   * connection untouched and reusable. Nothing downstream of the send may
   * raise for this option -- rb_mysql_result_to_obj in particular. */
  mysql2_canonicalize_force_encoding(current);
  rb_ivar_set(self, intern_current_query_options, current);

  Check_Type(sql, T_STRING);
  /* ensure the string is in the encoding the connection is expecting */
  args.sql = rb_str_export_to_enc(sql, rb_to_encoding(wrapper->encoding));
  args.sql_ptr = RSTRING_PTR(args.sql);
  args.sql_len = RSTRING_LEN(args.sql);
  args.completion.wrapper = wrapper;
  args.completion.completed = 0;

  rb_mysql_client_set_active_fiber(self, false);

  /* We're about to issue a new command: this is a safe point to close out
   * any statements that were GC'd while we were busy earlier, and to free
   * any abandoned result sets left over from a stream that was dropped
   * mid-iteration -- including one that hasn't been collected by GC yet,
   * which the reap below alone wouldn't catch (mysql2_abandon_active_stream).
   * Deliberately last, right before the actual network write below --
   * rb_ivar_set/rb_str_export_to_enc above can themselves allocate, and
   * under GC.stress (or just unlucky timing) that can be what triggers the
   * GC sweep that abandons a stream, so reaping any earlier can still leave
   * a fresh pending free undrained when we send. Must also run before the
   * state assignment below: mysql2_abandon_active_stream only acts while
   * state is still STREAMING. */
  mysql2_abandon_active_stream(wrapper);
  mysql2_reap_pending_result_frees(wrapper);
  mysql2_reap_pending_stmt_closes(wrapper);

  wrapper->state = MYSQL2_CLIENT_QUERYING;

#ifndef _WIN32
  rb_ensure(do_send_query, (VALUE)&args, disconnect_query_if_incomplete, (VALUE)&args.completion);
  (void)RB_GC_GUARD(sql);

  if (rb_hash_aref(current, sym_async) == Qtrue) {
    return Qnil;
  } else {
    async_args.fd = wrapper->client->net.fd;
    async_args.self = self;
    async_args.completion.wrapper = wrapper;
    async_args.completion.completed = 0;

    rb_ensure(do_query, (VALUE)&async_args, disconnect_query_if_incomplete, (VALUE)&async_args.completion);

    return rb_ensure(rb_mysql_client_async_result, self, disconnect_and_mark_inactive, self);
  }
#else
  do_send_query((VALUE)&args);
  (void)RB_GC_GUARD(sql);

  /* this will just block until the result is ready */
  return rb_ensure(rb_mysql_client_async_result, self, disconnect_and_mark_inactive, self);
#endif
}

/* call-seq:
 *    client.escape(string)
 *
 * Escape +string+ so that it may be used in a SQL statement.
 */
static VALUE rb_mysql_client_real_escape(VALUE self, VALUE str) {
  unsigned char *newStr;
  VALUE rb_str;
  unsigned long newLen, oldLen;
  rb_encoding *default_internal_enc;
  rb_encoding *conn_enc;
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  Check_Type(str, T_STRING);
  default_internal_enc = rb_default_internal_encoding();
  conn_enc = rb_to_encoding(wrapper->encoding);
  /* ensure the string is in the encoding the connection is expecting */
  str = rb_str_export_to_enc(str, conn_enc);

  oldLen = RSTRING_LEN(str);
  newStr = xmalloc(oldLen*2+1);

#ifdef HAVE_MYSQL_REAL_ESCAPE_STRING_QUOTE
  newLen = mysql_real_escape_string_quote(wrapper->client, (char *)newStr, RSTRING_PTR(str), oldLen, '\'');
#else
  newLen = mysql_real_escape_string(wrapper->client, (char *)newStr, RSTRING_PTR(str), oldLen);
#endif
  if (newLen == (unsigned long)-1) {
    xfree(newStr);
    rb_raise_mysql2_error(wrapper);
  }
  if (newLen == oldLen) {
    /* no need to return a new ruby string if nothing changed */
    if (default_internal_enc) {
      str = rb_str_export_to_enc(str, default_internal_enc);
    }
    xfree(newStr);
    return str;
  } else {
    rb_str = rb_str_new((const char*)newStr, newLen);
    /* mysql_real_escape_string() only backslash-escapes a handful of
     * syntax-breaking bytes; it doesn't transcode or validate the rest.
     * Tag the result with str's own encoding (already normalized to
     * conn_enc above for anything transcodable, left as-is for binary),
     * not unconditionally conn_enc -- otherwise binary input that happens
     * to contain an escapable byte comes back mislabeled, while identical
     * binary input that doesn't need escaping is correctly left alone. */
    rb_enc_associate(rb_str, rb_enc_get(str));
    if (default_internal_enc) {
      rb_str = rb_str_export_to_enc(rb_str, default_internal_enc);
    }
    xfree(newStr);
    return rb_str;
  }
}

static VALUE _mysql_client_options(VALUE self, int opt, VALUE value) {
  int result;
  const void *retval = NULL;
  unsigned int intval = 0;
  const char * charval = NULL;
  my_bool boolval;

  GET_CLIENT(self);

  REQUIRE_NOT_CONNECTED(wrapper);

  if (NIL_P(value))
      return Qfalse;

  switch(opt) {
    case MYSQL_OPT_CONNECT_TIMEOUT:
      intval = NUM2UINT(value);
      retval = &intval;
      break;

    case MYSQL_OPT_READ_TIMEOUT:
      intval = NUM2UINT(value);
      retval = &intval;
      break;

    case MYSQL_OPT_WRITE_TIMEOUT:
      intval = NUM2UINT(value);
      retval = &intval;
      break;

    case MYSQL_OPT_LOCAL_INFILE:
      intval = (value == Qfalse ? 0 : 1);
      retval = &intval;
      break;

    case MYSQL_OPT_RECONNECT:
      boolval = (value == Qfalse ? 0 : 1);
      retval = &boolval;
      break;

#ifdef MYSQL_SECURE_AUTH
    case MYSQL_SECURE_AUTH:
      boolval = (value == Qfalse ? 0 : 1);
      retval = &boolval;
      break;
#endif

    case MYSQL_READ_DEFAULT_FILE:
      charval = (const char *)StringValueCStr(value);
      retval  = charval;
      break;

    case MYSQL_READ_DEFAULT_GROUP:
      charval = (const char *)StringValueCStr(value);
      retval  = charval;
      break;

    case MYSQL_INIT_COMMAND:
      charval = (const char *)StringValueCStr(value);
      retval  = charval;
      break;

#ifdef HAVE_CONST_MYSQL_OPT_GET_SERVER_PUBLIC_KEY
    case MYSQL_OPT_GET_SERVER_PUBLIC_KEY:
      boolval = (value == Qfalse ? 0 : 1);
      retval = &boolval;
      break;
#endif

#ifdef HAVE_CONST_MYSQL_DEFAULT_AUTH
    case MYSQL_DEFAULT_AUTH:
      charval = (const char *)StringValueCStr(value);
      retval  = charval;
      break;
#endif

#ifdef HAVE_CONST_MYSQL_ENABLE_CLEARTEXT_PLUGIN
    case MYSQL_ENABLE_CLEARTEXT_PLUGIN:
      boolval = (value == Qfalse ? 0 : 1);
      retval = &boolval;
      break;
#endif

    default:
      return Qfalse;
  }

  result = mysql_options(wrapper->client, opt, retval);

  /* Zero means success */
  if (result != 0) {
    rb_warn("%s\n", mysql_error(wrapper->client));
  } else {
    /* Special case for options that are stored in the wrapper struct */
    switch (opt) {
      case MYSQL_OPT_RECONNECT:
        wrapper->reconnect_enabled = boolval;
        break;
      case MYSQL_OPT_CONNECT_TIMEOUT:
        wrapper->connect_timeout = intval;
        break;
    }
  }

  return (result == 0) ? Qtrue : Qfalse;
}

/* call-seq:
 *    client.info
 *
 * Returns a string that represents the client library version.
 */
static VALUE rb_mysql_client_info(RB_MYSQL_UNUSED VALUE klass) {
  VALUE version_info, version, header_version;
  version_info = rb_hash_new();

  version = rb_str_new2(mysql_get_client_info());
  header_version = rb_str_new2(MYSQL_LINK_VERSION);

  rb_enc_associate(version, rb_usascii_encoding());
  rb_enc_associate(header_version, rb_usascii_encoding());

  rb_hash_aset(version_info, sym_id, LONG2NUM(mysql_get_client_version()));
  rb_hash_aset(version_info, sym_version, version);
  rb_hash_aset(version_info, sym_header_version, header_version);

  return version_info;
}

/* call-seq:
 *    client.server_info
 *
 * Returns a string that represents the server version number
 */
static VALUE rb_mysql_client_server_info(VALUE self) {
  VALUE version, server_info;
  rb_encoding *default_internal_enc;
  rb_encoding *conn_enc;
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  default_internal_enc = rb_default_internal_encoding();
  conn_enc = rb_to_encoding(wrapper->encoding);

  version = rb_hash_new();
  rb_hash_aset(version, sym_id, LONG2FIX(mysql_get_server_version(wrapper->client)));
  server_info = rb_str_new2(mysql_get_server_info(wrapper->client));
  rb_enc_associate(server_info, conn_enc);
  if (default_internal_enc) {
    server_info = rb_str_export_to_enc(server_info, default_internal_enc);
  }
  rb_hash_aset(version, sym_version, server_info);
  return version;
}

/* call-seq:
 *    client.socket
 *
 * Return the file descriptor number for this client.
 */
#ifndef _WIN32
static VALUE rb_mysql_client_socket(VALUE self) {
  GET_CLIENT(self);
  REQUIRE_CONNECTED(wrapper);
  return INT2NUM(wrapper->client->net.fd);
}
#else
static VALUE rb_mysql_client_socket(RB_MYSQL_UNUSED VALUE self) {
  rb_raise(cMysql2Error, "Raw access to the mysql file descriptor isn't supported on Windows");
}
#endif

/* call-seq:
 *    client.last_id
 *
 * Returns the value generated for an AUTO_INCREMENT column by the previous INSERT or UPDATE
 * statement.
 */
static VALUE rb_mysql_client_last_id(VALUE self) {
  GET_CLIENT(self);
  REQUIRE_CONNECTED(wrapper);
  return ULL2NUM(mysql_insert_id(wrapper->client));
}

/* call-seq:
 *    client.session_track
 *
 * Returns information about changes to the session state on the server.
 */
static VALUE rb_mysql_client_session_track(VALUE self, VALUE type) {
#ifdef CLIENT_SESSION_TRACK
  const char *data;
  size_t length;
  my_ulonglong retVal;
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  retVal = mysql_session_track_get_first(wrapper->client, NUM2INT(type), &data, &length);
  if (retVal != 0) {
    return Qnil;
  }
  VALUE rbAry = rb_ary_new();
  VALUE rbFirst = rb_str_new(data, length);
  rb_ary_push(rbAry, rbFirst);
  while(mysql_session_track_get_next(wrapper->client, NUM2INT(type), &data, &length) == 0) {
    VALUE rbNext = rb_str_new(data, length);
    rb_ary_push(rbAry, rbNext);
  }
  return rbAry;
#else
  return Qnil;
#endif
}

/* call-seq:
 *    client.affected_rows
 *
 * returns the number of rows changed, deleted, or inserted by the last statement
 * if it was an UPDATE, DELETE, or INSERT.
 */
static VALUE rb_mysql_client_affected_rows(VALUE self) {
  uint64_t retVal;
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  retVal = wrapper->affected_rows;
  if (retVal == (my_ulonglong)-1) {
    rb_raise_mysql2_error(wrapper);
  }
  return ULL2NUM(retVal);
}

/* call-seq:
 *    client.thread_id
 *
 * Returns the thread ID of the current connection.
 */
static VALUE rb_mysql_client_thread_id(VALUE self) {
  unsigned long retVal;
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  retVal = mysql_thread_id(wrapper->client);
  return ULL2NUM(retVal);
}

static void *nogvl_select_db(void *ptr) {
  struct nogvl_select_db_args *args = ptr;

  if (mysql_select_db(args->mysql, args->db) == 0)
    return (void *)Qtrue;
  else
    return (void *)Qfalse;
}

/* call-seq:
 *    client.select_db(name)
 *
 * Causes the database specified by +name+ to become the default (current)
 * database on the connection specified by mysql.
 */
static VALUE rb_mysql_client_select_db(VALUE self, VALUE db)
{
  struct nogvl_select_db_args args;

  GET_CLIENT(self);
  REQUIRE_CONNECTED(wrapper);

  args.mysql = wrapper->client;
  args.db = StringValueCStr(db);

  if (rb_thread_call_without_gvl(nogvl_select_db, &args, RUBY_UBF_IO, 0) == Qfalse)
    rb_raise_mysql2_error(wrapper);

  /* This originates as a Ruby VALUE, but we're using its C pointer
   * directly -- keep the VALUE live on the stack so GC can't collect it
   * while we drop the GVL to make a MySQL API call. */
  (void)RB_GC_GUARD(db);

  return db;
}

static void *nogvl_ping(void *ptr) {
  MYSQL *client = ptr;

  return (void *)(mysql_ping(client) == 0 ? Qtrue : Qfalse);
}

#ifndef _WIN32
/* mysql_ping() has no non-blocking variant, and unlike a blocked query
 * read, libmysqlclient retries EINTR internally while pinging -- so an
 * interrupt (Thread#raise, Thread#kill, Timeout.timeout) delivered while
 * this is in flight is not guaranteed to land promptly. What we *can*
 * guarantee is that whenever it does land, active_fiber gets cleared and
 * the now-suspect connection gets invalidated, same as an interrupted
 * query -- otherwise every other caller of this Client is permanently
 * locked out with "This connection is in use by: <dead fiber>" since
 * ping's own active_fiber cleanup below never runs. */
static VALUE do_ping(VALUE args) {
  mysql_client_wrapper *wrapper = (mysql_client_wrapper *)args;
  VALUE result;

  if (!CONNECTED(wrapper)) {
    result = Qfalse;
  } else {
    result = (VALUE)rb_thread_call_without_gvl(nogvl_ping, wrapper->client, RUBY_UBF_IO, 0);
  }
  wrapper->active_fiber = Qnil;
  return result;
}
#endif

/* call-seq:
 *    client.ping
 *
 * Checks whether the connection to the server is working. If the connection
 * has gone down and auto-reconnect is enabled an attempt to reconnect is made.
 * If the connection is down and auto-reconnect is disabled, ping returns an
 * error.
 */
static VALUE rb_mysql_client_ping(VALUE self) {
  GET_CLIENT(self);
  rb_mysql_client_set_active_fiber(self, false);

  /* A low-traffic, frequently-called method; a good opportunistic safe
   * point to close out statements that were GC'd while we were busy, and to
   * free any abandoned result sets -- mysql_ping() itself sends a command,
   * so a still-live abandoned stream needs the same active drain as
   * rb_mysql_query, not just the reap. */
  mysql2_abandon_active_stream(wrapper);
  mysql2_reap_pending_result_frees(wrapper);
  mysql2_reap_pending_stmt_closes(wrapper);

#ifndef _WIN32
  return rb_rescue2(do_ping, (VALUE)wrapper, disconnect_and_raise, self, rb_eException, (VALUE)0);
#else
  VALUE result = Qnil;
  if (!CONNECTED(wrapper)) {
    result = Qfalse;
  } else {
    result = (VALUE)rb_thread_call_without_gvl(nogvl_ping, wrapper->client, RUBY_UBF_IO, 0);
  }
  wrapper->active_fiber = Qnil;
  return result;
#endif
}

/* call-seq:
 *    client.set_server_option(value)
 *
 * Enables or disables an option for the connection.
 * Read https://dev.mysql.com/doc/refman/5.7/en/mysql-set-server-option.html
 * for more information.
 */
static VALUE rb_mysql_client_set_server_option(VALUE self, VALUE value) {
  GET_CLIENT(self);

  if (mysql_set_server_option(wrapper->client, NUM2INT(value)) == 0) {
    return Qtrue;
  } else {
    return Qfalse;
  }
}

/* call-seq:
 *    client.more_results?
 *
 * Returns true or false if there are more results to process.
 */
static VALUE rb_mysql_client_more_results(VALUE self)
{
  GET_CLIENT(self);
  if (mysql_more_results(wrapper->client) == 0)
    return Qfalse;
  else
    return Qtrue;
}

#if defined(HAVE_MYSQL_NEXT_RESULT_NONBLOCKING) && !defined(_WIN32)
/* Polls mysql_next_result_nonblocking() (added in MySQL 8.0.16), which
 * never blocks by its own contract, instead of calling the blocking
 * mysql_next_result() directly. Mixing this with the ordinary blocking
 * API on the same connection is explicitly documented as supported, so
 * nothing else in this file needs to change:
 * https://dev.mysql.com/doc/c-api/8.0/en/c-api-asynchronous-interface-usage.html
 */
static enum net_async_status next_result_nonblocking(VALUE self, mysql_client_wrapper *wrapper) {
  enum net_async_status status;

  for (;;) {
    status = mysql_next_result_nonblocking(wrapper->client);
    if (status != NET_ASYNC_NOT_READY) {
      return status;
    }
    wait_for_readable_with_timeout(self, wrapper->client->net.fd);
  }
}
#else
/* Fallback for MariaDB (mysql_next_result_nonblocking doesn't exist there
 * under this name -- MariaDB Connector/C has its own mysql_next_result_start
 * / _cont pair instead, not yet wired up here) and for MySQL builds older
 * than 8.0.16. Releasing the GVL around the still-blocking call at least
 * lets other Ruby threads run during the wait; it does not make the call
 * interruptible via Thread#raise/Timeout.timeout the way the nonblocking
 * path above is, since libmysqlclient's own blocking read loop may retry
 * internally on the signal RUBY_UBF_IO sends. */
static void *nogvl_next_result(void *ptr) {
  mysql_client_wrapper *wrapper = ptr;
  /* Cast through intptr_t, not straight through void*, to round-trip a
   * signed int (including -1 for "no more results") intact. */
  return (void *)(intptr_t)mysql_next_result(wrapper->client);
}
#endif

static VALUE mysql2_next_result_reset_state(VALUE self) {
  GET_CLIENT(self);

  if (wrapper->state != MYSQL2_CLIENT_IDLE) {
    wrapper->state = MYSQL2_CLIENT_IDLE;
    mysql2_reap_pending_result_frees(wrapper);
    mysql2_reap_pending_stmt_closes(wrapper);
  }

  return Qnil;
}

static VALUE mysql2_next_result_body(VALUE self) {
  GET_CLIENT(self);

  /* Mark the connection busy for the duration of the wait: on the fast
   * path above, the GVL is no longer held for the whole call the way the
   * old blocking mysql_next_result() incidentally held it, so a Statement
   * on another thread getting GC'd during that window must not be allowed
   * to enqueue-and-flush a close over this same socket mid-command. See
   * the QUERYING/IDLE bracket rb_mysql_query uses for the same reason. */
  wrapper->state = MYSQL2_CLIENT_QUERYING;

#if defined(HAVE_MYSQL_NEXT_RESULT_NONBLOCKING) && !defined(_WIN32)
  {
    enum net_async_status status = next_result_nonblocking(self, wrapper);
    wrapper->affected_rows = mysql_affected_rows(wrapper->client);

    switch (status) {
      case NET_ASYNC_ERROR:
        rb_raise_mysql2_error(wrapper);
        return Qfalse; /* unreached */
      case NET_ASYNC_COMPLETE_NO_MORE_RESULTS:
        return Qfalse;
      case NET_ASYNC_COMPLETE:
      default:
        return Qtrue;
    }
  }
#else
  {
    int ret = (int)(intptr_t)rb_thread_call_without_gvl(nogvl_next_result, wrapper, RUBY_UBF_IO, 0);
    wrapper->affected_rows = mysql_affected_rows(wrapper->client);

    if (ret > 0) {
      rb_raise_mysql2_error(wrapper);
      return Qfalse; /* unreached */
    } else if (ret == 0) {
      return Qtrue;
    } else {
      return Qfalse;
    }
  }
#endif
}

/* call-seq:
 *    client.next_result
 *
 * Fetch the next result set from the server.
 * Returns true or false if there was another result in the multi-statement set.
 */
static VALUE rb_mysql_client_next_result(VALUE self)
{
  GET_CLIENT(self);
  REQUIRE_CONNECTED(wrapper);

  return rb_ensure(mysql2_next_result_body, self, mysql2_next_result_reset_state, self);
}

/* call-seq:
 *    client.store_result
 *
 * Return the next result object from a query which
 * yielded multiple result sets.
 */
static VALUE rb_mysql_client_store_result(VALUE self)
{
  GET_CLIENT(self);

  /* Honor :stream on later result sets of a multi-statement query the same
   * way async_result already does for the first one -- previously this
   * always called mysql_store_result regardless, silently buffering every
   * result set after the first even when the original query asked to
   * stream them (see #600). Also refreshes affected_rows: it's a
   * per-statement value at the C level, so it needs re-reading here too,
   * not just by async_result for the batch's first statement. */
  return mysql2_fetch_result_set(self, wrapper);
}

/* call-seq:
 *    client.encoding
 *
 * Returns the encoding set on the client.
 */
static VALUE rb_mysql_client_encoding(VALUE self) {
  GET_CLIENT(self);
  return wrapper->encoding;
}

/* call-seq:
 *    client.database
 *
 * Returns the currently selected database.
 *
 * The result may be stale if `session_track_schema` is disabled.  Read
 * https://dev.mysql.com/doc/refman/5.7/en/session-state-tracking.html for more
 * information.
 */
static VALUE rb_mysql_client_database(VALUE self) {
  GET_CLIENT(self);

  char *db = wrapper->client->db;
  // NULL when no database is selected against MariaDB servers < 12.3 (and
  // any MySQL server); an empty string against MariaDB servers >= 12.3,
  // confirmed by pairing MariaDB 11.8/12.3 client libraries against both
  // server versions independently -- the client library version made no
  // difference, only the server's did. Treat both as "no database".
  if (!db || db[0] == '\0') {
    return Qnil;
  }

  return rb_str_new_cstr(db);
}

/* call-seq:
 *    client.automatic_close?
 *
 * @return [Boolean]
 */
static VALUE get_automatic_close(VALUE self) {
  GET_CLIENT(self);
  return wrapper->automatic_close ? Qtrue : Qfalse;
}

/* call-seq:
 *    client.automatic_close = false
 *
 * Set this to +false+ to leave the connection open after it is garbage
 * collected. To avoid "Aborted connection" errors on the server, explicitly
 * call +close+ when the connection is no longer needed.
 *
 * @see http://dev.mysql.com/doc/en/communication-errors.html
 */
static VALUE set_automatic_close(VALUE self, VALUE value) {
  GET_CLIENT(self);
  if (RTEST(value)) {
    wrapper->automatic_close = 1;
  } else {
#ifndef _WIN32
    wrapper->automatic_close = 0;
#else
    rb_warn("Connections are always closed by garbage collector on Windows");
#endif
  }
  return value;
}

/* call-seq:
 *    client.reconnect = true
 *
 * Enable or disable the automatic reconnect behavior of libmysql.
 * Read http://dev.mysql.com/doc/refman/5.5/en/auto-reconnect.html
 * for more information.
 */
static VALUE set_reconnect(VALUE self, VALUE value) {
  return _mysql_client_options(self, MYSQL_OPT_RECONNECT, value);
}

static VALUE set_local_infile(VALUE self, VALUE value) {
  return _mysql_client_options(self, MYSQL_OPT_LOCAL_INFILE, value);
}

static VALUE set_connect_timeout(VALUE self, VALUE value) {
  long int sec;
  Check_Type(value, T_FIXNUM);
  sec = FIX2INT(value);
  if (sec < 0) {
    rb_raise(cMysql2Error, "connect_timeout must be a positive integer, you passed %ld", sec);
  }
  return _mysql_client_options(self, MYSQL_OPT_CONNECT_TIMEOUT, value);
}

static VALUE set_read_timeout(VALUE self, VALUE value) {
  long int sec;
  Check_Type(value, T_FIXNUM);
  sec = FIX2INT(value);
  if (sec < 0) {
    rb_raise(cMysql2Error, "read_timeout must be a positive integer, you passed %ld", sec);
  }
  /* Set the instance variable here even though _mysql_client_options
     might not succeed, because the timeout is used in other ways
     elsewhere */
  rb_ivar_set(self, intern_read_timeout, value);
  return _mysql_client_options(self, MYSQL_OPT_READ_TIMEOUT, value);
}

static VALUE set_write_timeout(VALUE self, VALUE value) {
  long int sec;
  Check_Type(value, T_FIXNUM);
  sec = FIX2INT(value);
  if (sec < 0) {
    rb_raise(cMysql2Error, "write_timeout must be a positive integer, you passed %ld", sec);
  }
  return _mysql_client_options(self, MYSQL_OPT_WRITE_TIMEOUT, value);
}

static VALUE set_charset_name(VALUE self, VALUE value) {
  char *charset_name;
  const struct mysql2_mysql_enc_name_to_rb_map *mysql2rb;
  rb_encoding *enc;
  VALUE rb_enc;
  GET_CLIENT(self);

  Check_Type(value, T_STRING);
  charset_name = RSTRING_PTR(value);

  mysql2rb = mysql2_mysql_enc_name_to_rb(charset_name, (unsigned int)RSTRING_LEN(value));
  if (mysql2rb == NULL || mysql2rb->rb_name == NULL) {
    VALUE inspect = rb_inspect(value);
    rb_raise(cMysql2Error, "Unsupported charset: '%s'", RSTRING_PTR(inspect));
  } else {
    enc = rb_enc_find(mysql2rb->rb_name);
    rb_enc = rb_enc_from_encoding(enc);
    wrapper->encoding = rb_enc;
  }

  if (mysql_options(wrapper->client, MYSQL_SET_CHARSET_NAME, charset_name)) {
    /* TODO: warning - unable to set charset */
    rb_warn("%s\n", mysql_error(wrapper->client));
  }

  return value;
}

static VALUE set_ssl_options(VALUE self, VALUE key, VALUE cert, VALUE ca, VALUE capath, VALUE cipher) {
  GET_CLIENT(self);

#ifdef HAVE_MYSQL_SSL_SET
  mysql_ssl_set(wrapper->client,
      NIL_P(key)    ? NULL : StringValueCStr(key),
      NIL_P(cert)   ? NULL : StringValueCStr(cert),
      NIL_P(ca)     ? NULL : StringValueCStr(ca),
      NIL_P(capath) ? NULL : StringValueCStr(capath),
      NIL_P(cipher) ? NULL : StringValueCStr(cipher));
#else
  /* mysql 8.3 does not provide mysql_ssl_set */
  if (!NIL_P(key)) {
    mysql_options(wrapper->client, MYSQL_OPT_SSL_KEY, StringValueCStr(key));
  }
  if (!NIL_P(cert)) {
    mysql_options(wrapper->client, MYSQL_OPT_SSL_CERT, StringValueCStr(cert));
  }
  if (!NIL_P(ca)) {
    mysql_options(wrapper->client, MYSQL_OPT_SSL_CA, StringValueCStr(ca));
  }
  if (!NIL_P(capath)) {
    mysql_options(wrapper->client, MYSQL_OPT_SSL_CAPATH, StringValueCStr(capath));
  }
  if (!NIL_P(cipher)) {
    mysql_options(wrapper->client, MYSQL_OPT_SSL_CIPHER, StringValueCStr(cipher));
  }
#endif

  return self;
}

static VALUE set_secure_auth(VALUE self, VALUE value) {
/* This option was deprecated in MySQL 5.x and removed in MySQL 8.0 */
#ifdef MYSQL_SECURE_AUTH
  return _mysql_client_options(self, MYSQL_SECURE_AUTH, value);
#else
  return Qfalse;
#endif
}

static VALUE set_read_default_file(VALUE self, VALUE value) {
  return _mysql_client_options(self, MYSQL_READ_DEFAULT_FILE, value);
}

static VALUE set_read_default_group(VALUE self, VALUE value) {
  return _mysql_client_options(self, MYSQL_READ_DEFAULT_GROUP, value);
}

static VALUE set_init_command(VALUE self, VALUE value) {
  return _mysql_client_options(self, MYSQL_INIT_COMMAND, value);
}

static VALUE set_get_server_public_key(VALUE self, VALUE value) {
#ifdef HAVE_CONST_MYSQL_OPT_GET_SERVER_PUBLIC_KEY
  return _mysql_client_options(self, MYSQL_OPT_GET_SERVER_PUBLIC_KEY, value);
#else
  rb_raise(cMysql2Error, "get-server-public-key is not available, you may need a newer MySQL client library");
#endif
}

static VALUE set_default_auth(VALUE self, VALUE value) {
#ifdef HAVE_CONST_MYSQL_DEFAULT_AUTH
  return _mysql_client_options(self, MYSQL_DEFAULT_AUTH, value);
#else
  rb_raise(cMysql2Error, "pluggable authentication is not available, you may need a newer MySQL client library");
#endif
}

static VALUE set_enable_cleartext_plugin(VALUE self, VALUE value) {
#ifdef HAVE_CONST_MYSQL_ENABLE_CLEARTEXT_PLUGIN
  return _mysql_client_options(self, MYSQL_ENABLE_CLEARTEXT_PLUGIN, value);
#else
  rb_raise(cMysql2Error, "enable-cleartext-plugin is not available, you may need a newer MySQL client library");
#endif
}

static VALUE initialize_ext(VALUE self) {
  GET_CLIENT(self);

  if ((VALUE)rb_thread_call_without_gvl(nogvl_init, wrapper, RUBY_UBF_IO, 0) == Qfalse) {
    /* TODO: warning - not enough memory? */
    rb_raise_mysql2_error(wrapper);
  }

  wrapper->initialized = 1;
  return self;
}

/* call-seq: client.prepare # => Mysql2::Statement
 *
 * Create a new prepared statement.
 */
static VALUE rb_mysql_client_prepare_statement(VALUE self, VALUE sql) {
  VALUE stmt;
  GET_CLIENT(self);
  REQUIRE_CONNECTED(wrapper);

  stmt = rb_mysql_stmt_new(self, sql);

  return stmt;
}

/* call-seq:
 *    client.prepared_statements
 *
 * Returns an array of prepared statement objects.
 */
static VALUE rb_mysql_client_prepared_statements_read(VALUE self) {
  GET_CLIENT(self);

  mysql2_reap_pending_result_frees(wrapper);
  mysql2_reap_pending_stmt_closes(wrapper);

  return rb_funcall(wrapper->prepared_statements, intern_values, 0);
}

/* call-seq:
 *    client.pending_prepared_statement_closes
 *
 * Returns the number of prepared statements that were garbage collected
 * while this connection was busy (mid-query or streaming), and are
 * therefore waiting for a safe point to actually notify the server. This
 * queue is not size-bounded; use this to observe whether it is growing
 * unexpectedly large (e.g. because the connection is kept busy streaming
 * for a long time while other statements on it keep churning). It drains
 * on the next query, prepare, execute, ping, or streaming completion.
 */
static VALUE rb_mysql_client_pending_prepared_statement_closes(VALUE self) {
  GET_CLIENT(self);

  return ULONG2NUM(wrapper->pending_stmt_close_count);
}

/* call-seq:
 *    client.pending_result_frees
 *
 * Returns the number of result sets (from a streaming query or streaming
 * prepared statement) that were abandoned mid-iteration and garbage
 * collected, and are therefore waiting for a safe point to actually
 * discard their unread rows from the connection. Mirrors
 * #pending_prepared_statement_closes; drains at the same safe points.
 */
static VALUE rb_mysql_client_pending_result_frees(VALUE self) {
  GET_CLIENT(self);

  return ULONG2NUM(wrapper->pending_result_free_count);
}

void init_mysql2_client(void) {
#ifdef _WIN32
  /* verify the libmysql we're about to use was the version we were built against
     https://github.com/luislavena/mysql-gem/commit/a600a9c459597da0712f70f43736e24b484f8a99 */
  int i;
  int dots = 0;
  const char *lib = mysql_get_client_info();

  for (i = 0; lib[i] != 0 && MYSQL_LINK_VERSION[i] != 0; i++) {
    if (lib[i] == '.') {
      dots++;
              /* we only compare MAJOR and MINOR */
      if (dots == 2) break;
    }
    if (lib[i] != MYSQL_LINK_VERSION[i]) {
      rb_raise(rb_eRuntimeError, "Incorrect MySQL client library version! This gem was compiled for %s but the client library is %s.", MYSQL_LINK_VERSION, lib);
    }
  }
#endif

  /* Initializing mysql library, so different threads could call Client.new */
  /* without race condition in the library */
  if (mysql_library_init(0, NULL, NULL) != 0) {
    rb_raise(rb_eRuntimeError, "Could not initialize MySQL client library");
  }

#if 0
  mMysql2      = rb_define_module("Mysql2"); Teach RDoc about Mysql2 constant.
#endif
  cMysql2Client = rb_define_class_under(mMysql2, "Client", rb_cObject);
  rb_global_variable(&cMysql2Client);

  rb_define_alloc_func(cMysql2Client, allocate);

  rb_define_singleton_method(cMysql2Client, "escape", rb_mysql_client_escape, 1);
  rb_define_singleton_method(cMysql2Client, "info", rb_mysql_client_info, 0);

  rb_define_method(cMysql2Client, "close", rb_mysql_client_close, 0);
  rb_define_method(cMysql2Client, "closed?", rb_mysql_client_closed, 0);
  rb_define_method(cMysql2Client, "abandon_results!", rb_mysql_client_abandon_results, 0);
  rb_define_method(cMysql2Client, "escape", rb_mysql_client_real_escape, 1);
  rb_define_method(cMysql2Client, "server_info", rb_mysql_client_server_info, 0);
  rb_define_method(cMysql2Client, "socket", rb_mysql_client_socket, 0);
  rb_define_method(cMysql2Client, "async_result", rb_mysql_client_async_result, 0);
  rb_define_method(cMysql2Client, "last_id", rb_mysql_client_last_id, 0);
  rb_define_method(cMysql2Client, "affected_rows", rb_mysql_client_affected_rows, 0);
  rb_define_method(cMysql2Client, "prepare", rb_mysql_client_prepare_statement, 1);
  rb_define_method(cMysql2Client, "prepared_statements", rb_mysql_client_prepared_statements_read, 0);
  rb_define_method(cMysql2Client, "pending_prepared_statement_closes", rb_mysql_client_pending_prepared_statement_closes, 0);
  rb_define_method(cMysql2Client, "pending_result_frees", rb_mysql_client_pending_result_frees, 0);
  rb_define_method(cMysql2Client, "thread_id", rb_mysql_client_thread_id, 0);
  rb_define_method(cMysql2Client, "ping", rb_mysql_client_ping, 0);
  rb_define_method(cMysql2Client, "select_db", rb_mysql_client_select_db, 1);
  rb_define_method(cMysql2Client, "set_server_option", rb_mysql_client_set_server_option, 1);
  rb_define_method(cMysql2Client, "more_results?", rb_mysql_client_more_results, 0);
  rb_define_method(cMysql2Client, "next_result", rb_mysql_client_next_result, 0);
  rb_define_method(cMysql2Client, "store_result", rb_mysql_client_store_result, 0);
  rb_define_method(cMysql2Client, "automatic_close?", get_automatic_close, 0);
  rb_define_method(cMysql2Client, "automatic_close=", set_automatic_close, 1);
  rb_define_method(cMysql2Client, "reconnect=", set_reconnect, 1);
  rb_define_method(cMysql2Client, "warning_count", rb_mysql_client_warning_count, 0);
  rb_define_method(cMysql2Client, "query_info_string", rb_mysql_info, 0);
  rb_define_method(cMysql2Client, "ssl_cipher", rb_mysql_get_ssl_cipher, 0);
  rb_define_method(cMysql2Client, "encoding", rb_mysql_client_encoding, 0);
  rb_define_method(cMysql2Client, "session_track", rb_mysql_client_session_track, 1);
  rb_define_method(cMysql2Client, "database", rb_mysql_client_database, 0);

  rb_define_private_method(cMysql2Client, "connect_timeout=", set_connect_timeout, 1);
  rb_define_private_method(cMysql2Client, "read_timeout=", set_read_timeout, 1);
  rb_define_private_method(cMysql2Client, "write_timeout=", set_write_timeout, 1);
  rb_define_private_method(cMysql2Client, "local_infile=", set_local_infile, 1);
  rb_define_private_method(cMysql2Client, "charset_name=", set_charset_name, 1);
  rb_define_private_method(cMysql2Client, "secure_auth=", set_secure_auth, 1);
  rb_define_private_method(cMysql2Client, "default_file=", set_read_default_file, 1);
  rb_define_private_method(cMysql2Client, "default_group=", set_read_default_group, 1);
  rb_define_private_method(cMysql2Client, "init_command=", set_init_command, 1);
  rb_define_private_method(cMysql2Client, "get_server_public_key=", set_get_server_public_key, 1);
  rb_define_private_method(cMysql2Client, "default_auth=", set_default_auth, 1);
  rb_define_private_method(cMysql2Client, "ssl_set", set_ssl_options, 5);
  rb_define_private_method(cMysql2Client, "ssl_mode=", rb_set_ssl_mode_option, 1);
  rb_define_private_method(cMysql2Client, "enable_cleartext_plugin=", set_enable_cleartext_plugin, 1);
  rb_define_private_method(cMysql2Client, "initialize_ext", initialize_ext, 0);
  rb_define_private_method(cMysql2Client, "connect", rb_mysql_connect, 9);
  rb_define_private_method(cMysql2Client, "_query", rb_mysql_query, 2);

  sym_id              = ID2SYM(rb_intern("id"));
  sym_version         = ID2SYM(rb_intern("version"));
  sym_header_version  = ID2SYM(rb_intern("header_version"));
  sym_async           = ID2SYM(rb_intern("async"));
  sym_symbolize_keys  = ID2SYM(rb_intern("symbolize_keys"));
  sym_as              = ID2SYM(rb_intern("as"));
  sym_array           = ID2SYM(rb_intern("array"));
  sym_stream          = ID2SYM(rb_intern("stream"));

  intern_brackets = rb_intern("[]");
  intern_merge = rb_intern("merge");
  intern_merge_bang = rb_intern("merge!");
  intern_new_with_args = rb_intern("new_with_args");
  intern_current_query_options = rb_intern("@current_query_options");
  intern_read_timeout = rb_intern("@read_timeout");
  intern_values = rb_intern("values");

#ifdef CLIENT_LONG_PASSWORD
  rb_const_set(cMysql2Client, rb_intern("LONG_PASSWORD"),
      LONG2NUM(CLIENT_LONG_PASSWORD));
#else
  /* HACK because MariaDB 10.2 no longer defines this constant,
   * but we're using it in our default connection flags. */
  rb_const_set(cMysql2Client, rb_intern("LONG_PASSWORD"), INT2NUM(0));
#endif

#ifdef CLIENT_FOUND_ROWS
  rb_const_set(cMysql2Client, rb_intern("FOUND_ROWS"),
      LONG2NUM(CLIENT_FOUND_ROWS));
#endif

#ifdef CLIENT_LONG_FLAG
  rb_const_set(cMysql2Client, rb_intern("LONG_FLAG"),
      LONG2NUM(CLIENT_LONG_FLAG));
#endif

#ifdef CLIENT_CONNECT_WITH_DB
  rb_const_set(cMysql2Client, rb_intern("CONNECT_WITH_DB"),
      LONG2NUM(CLIENT_CONNECT_WITH_DB));
#endif

#ifdef CLIENT_NO_SCHEMA
  rb_const_set(cMysql2Client, rb_intern("NO_SCHEMA"),
      LONG2NUM(CLIENT_NO_SCHEMA));
#endif

#ifdef CLIENT_COMPRESS
  rb_const_set(cMysql2Client, rb_intern("COMPRESS"), LONG2NUM(CLIENT_COMPRESS));
#endif

#ifdef CLIENT_ODBC
  rb_const_set(cMysql2Client, rb_intern("ODBC"), LONG2NUM(CLIENT_ODBC));
#endif

#ifdef CLIENT_LOCAL_FILES
  rb_const_set(cMysql2Client, rb_intern("LOCAL_FILES"),
      LONG2NUM(CLIENT_LOCAL_FILES));
#endif

#ifdef CLIENT_IGNORE_SPACE
  rb_const_set(cMysql2Client, rb_intern("IGNORE_SPACE"),
      LONG2NUM(CLIENT_IGNORE_SPACE));
#endif

#ifdef CLIENT_PROTOCOL_41
  rb_const_set(cMysql2Client, rb_intern("PROTOCOL_41"),
      LONG2NUM(CLIENT_PROTOCOL_41));
#endif

#ifdef CLIENT_INTERACTIVE
  rb_const_set(cMysql2Client, rb_intern("INTERACTIVE"),
      LONG2NUM(CLIENT_INTERACTIVE));
#endif

#ifdef CLIENT_SSL
  rb_const_set(cMysql2Client, rb_intern("SSL"), LONG2NUM(CLIENT_SSL));
#endif

#ifdef CLIENT_IGNORE_SIGPIPE
  rb_const_set(cMysql2Client, rb_intern("IGNORE_SIGPIPE"),
      LONG2NUM(CLIENT_IGNORE_SIGPIPE));
#endif

#ifdef CLIENT_TRANSACTIONS
  rb_const_set(cMysql2Client, rb_intern("TRANSACTIONS"),
      LONG2NUM(CLIENT_TRANSACTIONS));
#endif

#ifdef CLIENT_RESERVED
  rb_const_set(cMysql2Client, rb_intern("RESERVED"), LONG2NUM(CLIENT_RESERVED));
#endif

#ifdef CLIENT_SECURE_CONNECTION
  rb_const_set(cMysql2Client, rb_intern("SECURE_CONNECTION"),
      LONG2NUM(CLIENT_SECURE_CONNECTION));
#else
  /* HACK because MySQL5.7 no longer defines this constant,
   * but we're using it in our default connection flags. */
  rb_const_set(cMysql2Client, rb_intern("SECURE_CONNECTION"), LONG2NUM(0));
#endif

#ifdef HAVE_CONST_MYSQL_OPTION_MULTI_STATEMENTS_ON
  rb_const_set(cMysql2Client, rb_intern("OPTION_MULTI_STATEMENTS_ON"),
      LONG2NUM(MYSQL_OPTION_MULTI_STATEMENTS_ON));
#endif

#ifdef HAVE_CONST_MYSQL_OPTION_MULTI_STATEMENTS_OFF
  rb_const_set(cMysql2Client, rb_intern("OPTION_MULTI_STATEMENTS_OFF"),
      LONG2NUM(MYSQL_OPTION_MULTI_STATEMENTS_OFF));
#endif

#ifdef CLIENT_MULTI_STATEMENTS
  rb_const_set(cMysql2Client, rb_intern("MULTI_STATEMENTS"),
      LONG2NUM(CLIENT_MULTI_STATEMENTS));
#endif

#ifdef CLIENT_PS_MULTI_RESULTS
  rb_const_set(cMysql2Client, rb_intern("PS_MULTI_RESULTS"),
      LONG2NUM(CLIENT_PS_MULTI_RESULTS));
#endif

#ifdef CLIENT_SSL_VERIFY_SERVER_CERT
  rb_const_set(cMysql2Client, rb_intern("SSL_VERIFY_SERVER_CERT"),
      LONG2NUM(CLIENT_SSL_VERIFY_SERVER_CERT));
#endif

#ifdef CLIENT_REMEMBER_OPTIONS
  rb_const_set(cMysql2Client, rb_intern("REMEMBER_OPTIONS"),
      LONG2NUM(CLIENT_REMEMBER_OPTIONS));
#endif

#ifdef CLIENT_ALL_FLAGS
  rb_const_set(cMysql2Client, rb_intern("ALL_FLAGS"),
      LONG2NUM(CLIENT_ALL_FLAGS));
#endif

#ifdef CLIENT_BASIC_FLAGS
  rb_const_set(cMysql2Client, rb_intern("BASIC_FLAGS"),
      LONG2NUM(CLIENT_BASIC_FLAGS));
#endif

#ifdef CLIENT_CONNECT_ATTRS
  rb_const_set(cMysql2Client, rb_intern("CONNECT_ATTRS"),
      LONG2NUM(CLIENT_CONNECT_ATTRS));
#else
  /* HACK because MySQL 5.5 and earlier don't define this constant,
   * but we're using it in our default connection flags. */
  rb_const_set(cMysql2Client, rb_intern("CONNECT_ATTRS"),
      INT2NUM(0));
#endif

#ifdef CLIENT_SESSION_TRACK
  rb_const_set(cMysql2Client, rb_intern("SESSION_TRACK"), INT2NUM(CLIENT_SESSION_TRACK));
  /* From mysql_com.h -- but stable from at least 5.7.4 through 8.0.20 */
  rb_const_set(cMysql2Client, rb_intern("SESSION_TRACK_SYSTEM_VARIABLES"), INT2NUM(SESSION_TRACK_SYSTEM_VARIABLES));
  rb_const_set(cMysql2Client, rb_intern("SESSION_TRACK_SCHEMA"), INT2NUM(SESSION_TRACK_SCHEMA));
  rb_const_set(cMysql2Client, rb_intern("SESSION_TRACK_STATE_CHANGE"), INT2NUM(SESSION_TRACK_STATE_CHANGE));
  rb_const_set(cMysql2Client, rb_intern("SESSION_TRACK_GTIDS"), INT2NUM(SESSION_TRACK_GTIDS));
  rb_const_set(cMysql2Client, rb_intern("SESSION_TRACK_TRANSACTION_CHARACTERISTICS"), INT2NUM(SESSION_TRACK_TRANSACTION_CHARACTERISTICS));
  rb_const_set(cMysql2Client, rb_intern("SESSION_TRACK_TRANSACTION_STATE"), INT2NUM(SESSION_TRACK_TRANSACTION_STATE));
#endif

#if defined(FULL_SSL_MODE_SUPPORT) // MySQL 5.6.36 and MySQL 5.7.11 and above
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_DISABLED"), INT2NUM(SSL_MODE_DISABLED));
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_PREFERRED"), INT2NUM(SSL_MODE_PREFERRED));
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_REQUIRED"), INT2NUM(SSL_MODE_REQUIRED));
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_VERIFY_CA"), INT2NUM(SSL_MODE_VERIFY_CA));
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_VERIFY_IDENTITY"), INT2NUM(SSL_MODE_VERIFY_IDENTITY));
#else
#ifdef HAVE_CONST_MYSQL_OPT_SSL_VERIFY_SERVER_CERT // MySQL 5.7.3 - 5.7.10 & MariaDB 10.x and later
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_VERIFY_IDENTITY"), INT2NUM(SSL_MODE_VERIFY_IDENTITY));
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_VERIFY_CA"), INT2NUM(SSL_MODE_VERIFY_CA));
#endif
#ifdef HAVE_CONST_MYSQL_OPT_SSL_ENFORCE // MySQL 5.7.3 - 5.7.10 & MariaDB 10.x and later
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_DISABLED"), INT2NUM(SSL_MODE_DISABLED));
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_REQUIRED"), INT2NUM(SSL_MODE_REQUIRED));
#endif
#endif

#ifndef HAVE_CONST_SSL_MODE_DISABLED
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_DISABLED"), INT2NUM(0));
#endif
#ifndef HAVE_CONST_SSL_MODE_PREFERRED
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_PREFERRED"), INT2NUM(0));
#endif
#ifndef HAVE_CONST_SSL_MODE_REQUIRED
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_REQUIRED"), INT2NUM(0));
#endif
#ifndef HAVE_CONST_SSL_MODE_VERIFY_CA
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_VERIFY_CA"), INT2NUM(0));
#endif
#ifndef HAVE_CONST_SSL_MODE_VERIFY_IDENTITY
  rb_const_set(cMysql2Client, rb_intern("SSL_MODE_VERIFY_IDENTITY"), INT2NUM(0));
#endif

#ifdef HAVE_CONST_MYSQL_OPT_TLS_SNI_SERVERNAME
  rb_const_set(cMysql2Client, rb_intern("TLS_SNI_SUPPORTED"), Qtrue);
#else
  rb_const_set(cMysql2Client, rb_intern("TLS_SNI_SUPPORTED"), Qfalse);
#endif

#ifdef HAVE_MYSQL_REAL_ESCAPE_STRING_QUOTE
  rb_const_set(cMysql2Client, rb_intern("ESCAPE_QUOTE_SUPPORTED"), Qtrue);
#else
  rb_const_set(cMysql2Client, rb_intern("ESCAPE_QUOTE_SUPPORTED"), Qfalse);
#endif
}
