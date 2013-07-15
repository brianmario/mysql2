#include <mysql2_ext.h>
#include <client.h>
#include <errno.h>
#ifndef _WIN32
#include <sys/socket.h>
#endif
#include <unistd.h>
#include "wait_for_single_fd.h"

#include "mysql_enc_name_to_ruby.h"

VALUE cMysql2Client;
extern VALUE mMysql2, cMysql2Error;
static VALUE sym_id, sym_version, sym_async, sym_symbolize_keys, sym_as, sym_array, sym_stream;
static ID intern_merge, intern_merge_bang, intern_error_number_eql, intern_sql_state_eql;

#ifndef HAVE_RB_HASH_DUP
static VALUE rb_hash_dup(VALUE other) {
  return rb_funcall(rb_cHash, rb_intern("[]"), 1, other);
}
#endif

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

#define MARK_CONN_INACTIVE(conn) \
  wrapper->active_thread = Qnil;

#define GET_CLIENT(self) \
  mysql_client_wrapper *wrapper; \
  Data_Get_Struct(self, mysql_client_wrapper, wrapper)

/*
 * compatability with mysql-connector-c, where LIBMYSQL_VERSION is the correct
 * variable to use, but MYSQL_SERVER_VERSION gives the correct numbers when
 * linking against the server itself
 */
#ifdef LIBMYSQL_VERSION
  #define MYSQL_LINK_VERSION LIBMYSQL_VERSION
#else
  #define MYSQL_LINK_VERSION MYSQL_SERVER_VERSION
#endif

/*
 * used to pass all arguments to mysql_real_connect while inside
 * rb_thread_blocking_region
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
 * rb_thread_blocking_region
 */
struct nogvl_send_query_args {
  MYSQL *mysql;
  VALUE sql;
  const char *sql_ptr;
  long sql_len;
  mysql_client_wrapper *wrapper;
};

/*
 * used to pass all arguments to mysql_select_db while inside
 * rb_thread_blocking_region
 */
struct nogvl_select_db_args {
  MYSQL *mysql;
  char *db;
};

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
    rb_gc_mark(w->encoding);
    rb_gc_mark(w->active_thread);
  }
}

static VALUE rb_raise_mysql2_error(mysql_client_wrapper *wrapper) {
  VALUE rb_error_msg = rb_str_new2(mysql_error(wrapper->client));
  VALUE rb_sql_state = rb_tainted_str_new2(mysql_sqlstate(wrapper->client));
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc = rb_default_internal_encoding();
  rb_encoding *conn_enc = rb_to_encoding(wrapper->encoding);

  rb_enc_associate(rb_error_msg, conn_enc);
  rb_enc_associate(rb_sql_state, conn_enc);
  if (default_internal_enc) {
    rb_error_msg = rb_str_export_to_enc(rb_error_msg, default_internal_enc);
    rb_sql_state = rb_str_export_to_enc(rb_sql_state, default_internal_enc);
  }
#endif

  VALUE e = rb_exc_new3(cMysql2Error, rb_error_msg);
  rb_funcall(e, intern_error_number_eql, 1, UINT2NUM(mysql_errno(wrapper->client)));
  rb_funcall(e, intern_sql_state_eql, 1, rb_sql_state);
  rb_exc_raise(e);
  return Qnil;
}

static VALUE nogvl_init(void *ptr) {
  MYSQL *client;

  /* may initialize embedded server and read /etc/services off disk */
  client = mysql_init((MYSQL *)ptr);
  return client ? Qtrue : Qfalse;
}

static VALUE nogvl_connect(void *ptr) {
  struct nogvl_connect_args *args = ptr;
  MYSQL *client;

  client = mysql_real_connect(args->mysql, args->host,
                              args->user, args->passwd,
                              args->db, args->port, args->unix_socket,
                              args->client_flag);

  return client ? Qtrue : Qfalse;
}

static VALUE nogvl_close(void *ptr) {
  mysql_client_wrapper *wrapper;
#ifndef _WIN32
  int flags;
#endif
  wrapper = ptr;
  if (wrapper->connected) {
    wrapper->active_thread = Qnil;
    wrapper->connected = 0;
    /*
     * we'll send a QUIT message to the server, but that message is more of a
     * formality than a hard requirement since the socket is getting shutdown
     * anyways, so ensure the socket write does not block our interpreter
     *
     *
     * if the socket is dead we have no chance of blocking,
     * so ignore any potential fcntl errors since they don't matter
     */
#ifndef _WIN32
    flags = fcntl(wrapper->client->net.fd, F_GETFL);
    if (flags > 0 && !(flags & O_NONBLOCK))
      fcntl(wrapper->client->net.fd, F_SETFL, flags | O_NONBLOCK);
#endif

    mysql_close(wrapper->client);
  }

  return Qnil;
}

static void rb_mysql_client_free(void *ptr) {
  mysql_client_wrapper *wrapper = (mysql_client_wrapper *)ptr;

  wrapper->refcount--;
  if (wrapper->refcount == 0) {
    nogvl_close(wrapper);
    xfree(wrapper->client);
    xfree(wrapper);
  }
}

static VALUE allocate(VALUE klass) {
  VALUE obj;
  mysql_client_wrapper * wrapper;
  obj = Data_Make_Struct(klass, mysql_client_wrapper, rb_mysql_client_mark, rb_mysql_client_free, wrapper);
  wrapper->encoding = Qnil;
  wrapper->active_thread = Qnil;
  wrapper->reconnect_enabled = 0;
  wrapper->connected = 0; /* means that a database connection is open */
  wrapper->initialized = 0; /* means that that the wrapper is initialized */
  wrapper->refcount = 1;
  wrapper->client = (MYSQL*)xmalloc(sizeof(MYSQL));
  return obj;
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

  newLen = mysql_escape_string((char *)newStr, StringValuePtr(str), oldLen);
  if (newLen == oldLen) {
    /* no need to return a new ruby string if nothing changed */
    xfree(newStr);
    return str;
  } else {
    rb_str = rb_str_new((const char*)newStr, newLen);
#ifdef HAVE_RUBY_ENCODING_H
    rb_enc_copy(rb_str, str);
#endif
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
#ifdef HAVE_RUBY_ENCODING_H
  rb_enc_associate(rb_str, rb_utf8_encoding());
#endif

  return rb_str;
}

static VALUE rb_connect(VALUE self, VALUE user, VALUE pass, VALUE host, VALUE port, VALUE database, VALUE socket, VALUE flags) {
  struct nogvl_connect_args args;
  VALUE rv;
  GET_CLIENT(self);

  args.host = NIL_P(host) ? "localhost" : StringValuePtr(host);
  args.unix_socket = NIL_P(socket) ? NULL : StringValuePtr(socket);
  args.port = NIL_P(port) ? 3306 : NUM2INT(port);
  args.user = NIL_P(user) ? NULL : StringValuePtr(user);
  args.passwd = NIL_P(pass) ? NULL : StringValuePtr(pass);
  args.db = NIL_P(database) ? NULL : StringValuePtr(database);
  args.mysql = wrapper->client;
  args.client_flag = NUM2ULONG(flags);

  rv = rb_thread_blocking_region(nogvl_connect, &args, RUBY_UBF_IO, 0);
  if (rv == Qfalse) {
    while (rv == Qfalse && errno == EINTR && !mysql_errno(wrapper->client)) {
      errno = 0;
      rv = rb_thread_blocking_region(nogvl_connect, &args, RUBY_UBF_IO, 0);
    }
    if (rv == Qfalse)
      return rb_raise_mysql2_error(wrapper);
  }

  wrapper->connected = 1;
  return self;
}

/*
 * Immediately disconnect from the server, normally the garbage collector
 * will disconnect automatically when a connection is no longer needed.
 * Explicitly closing this will free up server resources sooner than waiting
 * for the garbage collector.
 */
static VALUE rb_mysql_client_close(VALUE self) {
  GET_CLIENT(self);

  if (wrapper->connected) {
    rb_thread_blocking_region(nogvl_close, wrapper, RUBY_UBF_IO, 0);
  }

  return Qnil;
}

/*
 * mysql_send_query is unlikely to block since most queries are small
 * enough to fit in a socket buffer, but sometimes large UPDATE and
 * INSERTs will cause the process to block
 */
static VALUE nogvl_send_query(void *ptr) {
  struct nogvl_send_query_args *args = ptr;
  int rv;

  rv = mysql_send_query(args->mysql, args->sql_ptr, args->sql_len);

  return rv == 0 ? Qtrue : Qfalse;
}

static VALUE do_send_query(void *args) {
  struct nogvl_send_query_args *query_args = args;
  mysql_client_wrapper *wrapper = query_args->wrapper;
  if (rb_thread_blocking_region(nogvl_send_query, args, RUBY_UBF_IO, 0) == Qfalse) {
    /* an error occurred, we're not active anymore */
    MARK_CONN_INACTIVE(self);
    return rb_raise_mysql2_error(wrapper);
  }
  return Qnil;
}

/*
 * even though we did rb_thread_select before calling this, a large
 * response can overflow the socket buffers and cause us to eventually
 * block while calling mysql_read_query_result
 */
static VALUE nogvl_read_query_result(void *ptr) {
  MYSQL * client = ptr;
  my_bool res = mysql_read_query_result(client);

  return res == 0 ? Qtrue : Qfalse;
}

static VALUE nogvl_do_result(void *ptr, char use_result) {
  mysql_client_wrapper *wrapper;
  MYSQL_RES *result;

  wrapper = (mysql_client_wrapper *)ptr;
  if(use_result) {
    result = mysql_use_result(wrapper->client);
  } else {
    result = mysql_store_result(wrapper->client);
  }

  /* once our result is stored off, this connection is
     ready for another command to be issued */
  wrapper->active_thread = Qnil;

  return (VALUE)result;
}

/* mysql_store_result may (unlikely) read rows off the socket */
static VALUE nogvl_store_result(void *ptr) {
  return nogvl_do_result(ptr, 0);
}

static VALUE nogvl_use_result(void *ptr) {
  return nogvl_do_result(ptr, 1);
}

/* call-seq:
 *    client.async_result
 *
 * Returns the result for the last async issued query.
 */
static VALUE rb_mysql_client_async_result(VALUE self) {
  MYSQL_RES * result;
  VALUE resultObj;
  VALUE current, is_streaming;
  GET_CLIENT(self);

  /* if we're not waiting on a result, do nothing */
  if (NIL_P(wrapper->active_thread))
    return Qnil;

  REQUIRE_CONNECTED(wrapper);
  if (rb_thread_blocking_region(nogvl_read_query_result, wrapper->client, RUBY_UBF_IO, 0) == Qfalse) {
    /* an error occurred, mark this connection inactive */
    MARK_CONN_INACTIVE(self);
    return rb_raise_mysql2_error(wrapper);
  }

  is_streaming = rb_hash_aref(rb_iv_get(self, "@current_query_options"), sym_stream);
  if(is_streaming == Qtrue) {
    result = (MYSQL_RES *)rb_thread_blocking_region(nogvl_use_result, wrapper, RUBY_UBF_IO, 0);
  } else {
    result = (MYSQL_RES *)rb_thread_blocking_region(nogvl_store_result, wrapper, RUBY_UBF_IO, 0);
  }

  if (result == NULL) {
    if (mysql_errno(wrapper->client) != 0) {
      MARK_CONN_INACTIVE(self);
      rb_raise_mysql2_error(wrapper);
    }
    /* no data and no error, so query was not a SELECT */
    return Qnil;
  }

  current = rb_hash_dup(rb_iv_get(self, "@current_query_options"));
  RB_GC_GUARD(current);
  Check_Type(current, T_HASH);
  resultObj = rb_mysql_result_to_obj(self, wrapper->encoding, current, result);

  return resultObj;
}

#ifndef _WIN32
struct async_query_args {
  int fd;
  VALUE self;
};

static VALUE disconnect_and_raise(VALUE self, VALUE error) {
  GET_CLIENT(self);

  wrapper->active_thread = Qnil;
  wrapper->connected = 0;

  /* manually close the socket for read/write
     this feels dirty, but is there another way? */
  close(wrapper->client->net.fd);
  wrapper->client->net.fd = -1;

  rb_exc_raise(error);

  return Qnil;
}

static VALUE do_query(void *args) {
  struct async_query_args *async_args;
  struct timeval tv;
  struct timeval* tvp;
  long int sec;
  int retval;
  VALUE read_timeout;

  async_args = (struct async_query_args *)args;
  read_timeout = rb_iv_get(async_args->self, "@read_timeout");

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

  for(;;) {
    retval = rb_wait_for_single_fd(async_args->fd, RB_WAITFD_IN, tvp);

    if (retval == 0) {
      rb_raise(cMysql2Error, "Timeout waiting for a response from the last query. (waited %d seconds)", FIX2INT(read_timeout));
    }

    if (retval < 0) {
      rb_sys_fail(0);
    }

    if (retval > 0) {
      break;
    }
  }

  return Qnil;
}
#else
static VALUE finish_and_mark_inactive(void *args) {
  VALUE self;
  MYSQL_RES *result;

  self = (VALUE)args;

  GET_CLIENT(self);

  if (!NIL_P(wrapper->active_thread)) {
    /* if we got here, the result hasn't been read off the wire yet
       so lets do that and then throw it away because we have no way
       of getting it back up to the caller from here */
    result = (MYSQL_RES *)rb_thread_blocking_region(nogvl_store_result, wrapper, RUBY_UBF_IO, 0);
    mysql_free_result(result);

    wrapper->active_thread = Qnil;
  }

  return Qnil;
}
#endif

/* call-seq:
 *    client.abandon_results!
 *
 * When using MULTI_STATEMENTS support, calling this will throw
 * away any unprocessed results as fast as it can in order to
 * put the connection back into a state where queries can be issued
 * again.
 */
static VALUE rb_mysql_client_abandon_results(VALUE self) {
  GET_CLIENT(self);

  MYSQL_RES *result;
  int ret;

  while (mysql_more_results(wrapper->client) == 1) {
    ret = mysql_next_result(wrapper->client);
    if (ret > 0) {
      rb_raise_mysql2_error(wrapper);
    }

    result = (MYSQL_RES *)rb_thread_blocking_region(nogvl_store_result, wrapper, RUBY_UBF_IO, 0);

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
 * options, see @@default_query_options on the Mysql2::Client class.
 */
static VALUE rb_mysql_client_query(int argc, VALUE * argv, VALUE self) {
#ifndef _WIN32
  struct async_query_args async_args;
#endif
  struct nogvl_send_query_args args;
  int async = 0;
  VALUE opts, current;
  VALUE thread_current = rb_thread_current();
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *conn_enc;
#endif
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  args.mysql = wrapper->client;

  current = rb_hash_dup(rb_iv_get(self, "@query_options"));
  RB_GC_GUARD(current);
  Check_Type(current, T_HASH);
  rb_iv_set(self, "@current_query_options", current);

  if (rb_scan_args(argc, argv, "11", &args.sql, &opts) == 2) {
    rb_funcall(current, intern_merge_bang, 1, opts);

    if (rb_hash_aref(current, sym_async) == Qtrue) {
      async = 1;
    }
  }

  Check_Type(args.sql, T_STRING);
#ifdef HAVE_RUBY_ENCODING_H
  conn_enc = rb_to_encoding(wrapper->encoding);
  /* ensure the string is in the encoding the connection is expecting */
  args.sql = rb_str_export_to_enc(args.sql, conn_enc);
#endif
  args.sql_ptr = StringValuePtr(args.sql);
  args.sql_len = RSTRING_LEN(args.sql);

  /* see if this connection is still waiting on a result from a previous query */
  if (NIL_P(wrapper->active_thread)) {
    /* mark this connection active */
    wrapper->active_thread = thread_current;
  } else if (wrapper->active_thread == thread_current) {
    rb_raise(cMysql2Error, "This connection is still waiting for a result, try again once you have the result");
  } else {
    VALUE inspect = rb_inspect(wrapper->active_thread);
    const char *thr = StringValueCStr(inspect);

    rb_raise(cMysql2Error, "This connection is in use by: %s", thr);
    RB_GC_GUARD(inspect);
  }

  args.wrapper = wrapper;

#ifndef _WIN32
  rb_rescue2(do_send_query, (VALUE)&args, disconnect_and_raise, self, rb_eException, (VALUE)0);

  if (!async) {
    async_args.fd = wrapper->client->net.fd;
    async_args.self = self;

    rb_rescue2(do_query, (VALUE)&async_args, disconnect_and_raise, self, rb_eException, (VALUE)0);

    return rb_mysql_client_async_result(self);
  } else {
    return Qnil;
  }
#else
  do_send_query(&args);

  /* this will just block until the result is ready */
  return rb_ensure(rb_mysql_client_async_result, self, finish_and_mark_inactive, self);
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
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc;
  rb_encoding *conn_enc;
#endif
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  Check_Type(str, T_STRING);
#ifdef HAVE_RUBY_ENCODING_H
  default_internal_enc = rb_default_internal_encoding();
  conn_enc = rb_to_encoding(wrapper->encoding);
  /* ensure the string is in the encoding the connection is expecting */
  str = rb_str_export_to_enc(str, conn_enc);
#endif

  oldLen = RSTRING_LEN(str);
  newStr = xmalloc(oldLen*2+1);

  newLen = mysql_real_escape_string(wrapper->client, (char *)newStr, StringValuePtr(str), oldLen);
  if (newLen == oldLen) {
    /* no need to return a new ruby string if nothing changed */
    xfree(newStr);
    return str;
  } else {
    rb_str = rb_str_new((const char*)newStr, newLen);
#ifdef HAVE_RUBY_ENCODING_H
    rb_enc_associate(rb_str, conn_enc);
    if (default_internal_enc) {
      rb_str = rb_str_export_to_enc(rb_str, default_internal_enc);
    }
#endif
    xfree(newStr);
    return rb_str;
  }
}

static VALUE _mysql_client_options(VALUE self, int opt, VALUE value) {
  int result;
  void *retval = NULL;
  unsigned int intval = 0;
  my_bool boolval;

  GET_CLIENT(self);

  REQUIRE_NOT_CONNECTED(wrapper);

  if (NIL_P(value))
      return Qfalse;

  switch(opt) {
    case MYSQL_OPT_CONNECT_TIMEOUT:
      intval = NUM2INT(value);
      retval = &intval;
      break;

    case MYSQL_OPT_READ_TIMEOUT:
      intval = NUM2INT(value);
      retval = &intval;
      break;

    case MYSQL_OPT_WRITE_TIMEOUT:
      intval = NUM2INT(value);
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

    default:
      return Qfalse;
  }

  result = mysql_options(wrapper->client, opt, retval);

  /* Zero means success */
  if (result != 0) {
    rb_warn("%s\n", mysql_error(wrapper->client));
  } else {
    /* Special case for reconnect, this option is also stored in the wrapper struct */
    if (opt == MYSQL_OPT_RECONNECT)
      wrapper->reconnect_enabled = boolval;
  }

  return (result == 0) ? Qtrue : Qfalse;
}

/* call-seq:
 *    client.info
 *
 * Returns a string that represents the client library version.
 */
static VALUE rb_mysql_client_info(VALUE self) {
  VALUE version, client_info;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc;
  rb_encoding *conn_enc;
#endif
  GET_CLIENT(self);
  version = rb_hash_new();

#ifdef HAVE_RUBY_ENCODING_H
  default_internal_enc = rb_default_internal_encoding();
  conn_enc = rb_to_encoding(wrapper->encoding);
#endif

  rb_hash_aset(version, sym_id, LONG2NUM(mysql_get_client_version()));
  client_info = rb_str_new2(mysql_get_client_info());
#ifdef HAVE_RUBY_ENCODING_H
  rb_enc_associate(client_info, conn_enc);
  if (default_internal_enc) {
    client_info = rb_str_export_to_enc(client_info, default_internal_enc);
  }
#endif
  rb_hash_aset(version, sym_version, client_info);
  return version;
}

/* call-seq:
 *    client.server_info
 *
 * Returns a string that represents the server version number
 */
static VALUE rb_mysql_client_server_info(VALUE self) {
  VALUE version, server_info;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc;
  rb_encoding *conn_enc;
#endif
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
#ifdef HAVE_RUBY_ENCODING_H
  default_internal_enc = rb_default_internal_encoding();
  conn_enc = rb_to_encoding(wrapper->encoding);
#endif

  version = rb_hash_new();
  rb_hash_aset(version, sym_id, LONG2FIX(mysql_get_server_version(wrapper->client)));
  server_info = rb_str_new2(mysql_get_server_info(wrapper->client));
#ifdef HAVE_RUBY_ENCODING_H
  rb_enc_associate(server_info, conn_enc);
  if (default_internal_enc) {
    server_info = rb_str_export_to_enc(server_info, default_internal_enc);
  }
#endif
  rb_hash_aset(version, sym_version, server_info);
  return version;
}

/* call-seq:
 *    client.socket
 *
 * Return the file descriptor number for this client.
 */
static VALUE rb_mysql_client_socket(VALUE self) {
  GET_CLIENT(self);
#ifndef _WIN32
  REQUIRE_CONNECTED(wrapper);
  int fd_set_fd = wrapper->client->net.fd;
  return INT2NUM(fd_set_fd);
#else
  rb_raise(cMysql2Error, "Raw access to the mysql file descriptor isn't supported on Windows");
#endif
}

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
 *    client.affected_rows
 *
 * returns the number of rows changed, deleted, or inserted by the last statement
 * if it was an UPDATE, DELETE, or INSERT.
 */
static VALUE rb_mysql_client_affected_rows(VALUE self) {
  my_ulonglong retVal;
  GET_CLIENT(self);

  REQUIRE_CONNECTED(wrapper);
  retVal = mysql_affected_rows(wrapper->client);
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

static VALUE nogvl_select_db(void *ptr) {
  struct nogvl_select_db_args *args = ptr;

  if (mysql_select_db(args->mysql, args->db) == 0)
    return Qtrue;
  else
    return Qfalse;
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
  args.db = StringValuePtr(db);

  if (rb_thread_blocking_region(nogvl_select_db, &args, RUBY_UBF_IO, 0) == Qfalse)
    rb_raise_mysql2_error(wrapper);

  return db;
}

static VALUE nogvl_ping(void *ptr) {
  MYSQL *client = ptr;

  return mysql_ping(client) == 0 ? Qtrue : Qfalse;
}

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

  if (!wrapper->connected) {
    return Qfalse;
  } else {
    return rb_thread_blocking_region(nogvl_ping, wrapper->client, RUBY_UBF_IO, 0);
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

/* call-seq:
 *    client.next_result
 *
 * Fetch the next result set from the server.
 * Returns nothing.
 */
static VALUE rb_mysql_client_next_result(VALUE self)
{
    GET_CLIENT(self);
    int ret;
    ret = mysql_next_result(wrapper->client);
    if (ret > 0) {
      rb_raise_mysql2_error(wrapper);
      return Qfalse;
    } else if (ret == 0) {
      return Qtrue;
    } else {
      return Qfalse;
    }
}

/* call-seq:
 *    client.store_result
 *
 * Return the next result object from a query which
 * yielded multiple result sets.
 */
static VALUE rb_mysql_client_store_result(VALUE self)
{
  MYSQL_RES * result;
  VALUE resultObj;
  VALUE current;
  GET_CLIENT(self);

  result = (MYSQL_RES *)rb_thread_blocking_region(nogvl_store_result, wrapper, RUBY_UBF_IO, 0);

  if (result == NULL) {
    if (mysql_errno(wrapper->client) != 0) {
      rb_raise_mysql2_error(wrapper);
    }
    /* no data and no error, so query was not a SELECT */
    return Qnil;
  }

  current = rb_hash_dup(rb_iv_get(self, "@current_query_options"));
  RB_GC_GUARD(current);
  Check_Type(current, T_HASH);
  resultObj = rb_mysql_result_to_obj(self, wrapper->encoding, current, result);

  return resultObj;
}

#ifdef HAVE_RUBY_ENCODING_H
/* call-seq:
 *    client.encoding
 *
 * Returns the encoding set on the client.
 */
static VALUE rb_mysql_client_encoding(VALUE self) {
  GET_CLIENT(self);
  return wrapper->encoding;
}
#endif

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
  rb_iv_set(self, "@read_timeout", value);
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
  size_t charset_name_len;
  const struct mysql2_mysql_enc_name_to_rb_map *mysql2rb;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *enc;
  VALUE rb_enc;
#endif
  GET_CLIENT(self);

  charset_name = RSTRING_PTR(value);
  charset_name_len = RSTRING_LEN(value);

#ifdef HAVE_RUBY_ENCODING_H
  mysql2rb = mysql2_mysql_enc_name_to_rb(charset_name, charset_name_len);
  if (mysql2rb == NULL || mysql2rb->rb_name == NULL) {
    VALUE inspect = rb_inspect(value);
    rb_raise(cMysql2Error, "Unsupported charset: '%s'", RSTRING_PTR(inspect));
  } else {
    enc = rb_enc_find(mysql2rb->rb_name);
    rb_enc = rb_enc_from_encoding(enc);
    wrapper->encoding = rb_enc;
  }
#endif

  if (mysql_options(wrapper->client, MYSQL_SET_CHARSET_NAME, charset_name)) {
    /* TODO: warning - unable to set charset */
    rb_warn("%s\n", mysql_error(wrapper->client));
  }

  return value;
}

static VALUE set_ssl_options(VALUE self, VALUE key, VALUE cert, VALUE ca, VALUE capath, VALUE cipher) {
  GET_CLIENT(self);

  mysql_ssl_set(wrapper->client,
      NIL_P(key) ? NULL : StringValuePtr(key),
      NIL_P(cert) ? NULL : StringValuePtr(cert),
      NIL_P(ca) ? NULL : StringValuePtr(ca),
      NIL_P(capath) ? NULL : StringValuePtr(capath),
      NIL_P(cipher) ? NULL : StringValuePtr(cipher));

  return self;
}

static VALUE initialize_ext(VALUE self) {
  GET_CLIENT(self);

  if (rb_thread_blocking_region(nogvl_init, wrapper->client, RUBY_UBF_IO, 0) == Qfalse) {
    /* TODO: warning - not enough memory? */
    return rb_raise_mysql2_error(wrapper);
  }

  wrapper->initialized = 1;
  return self;
}

void init_mysql2_client() {
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
      return;
    }
  }

#if 0
  mMysql2      = rb_define_module("Mysql2"); Teach RDoc about Mysql2 constant.
#endif
  cMysql2Client = rb_define_class_under(mMysql2, "Client", rb_cObject);

  rb_define_alloc_func(cMysql2Client, allocate);

  rb_define_singleton_method(cMysql2Client, "escape", rb_mysql_client_escape, 1);

  rb_define_method(cMysql2Client, "close", rb_mysql_client_close, 0);
  rb_define_method(cMysql2Client, "query", rb_mysql_client_query, -1);
  rb_define_method(cMysql2Client, "abandon_results!", rb_mysql_client_abandon_results, 0);
  rb_define_method(cMysql2Client, "escape", rb_mysql_client_real_escape, 1);
  rb_define_method(cMysql2Client, "info", rb_mysql_client_info, 0);
  rb_define_method(cMysql2Client, "server_info", rb_mysql_client_server_info, 0);
  rb_define_method(cMysql2Client, "socket", rb_mysql_client_socket, 0);
  rb_define_method(cMysql2Client, "async_result", rb_mysql_client_async_result, 0);
  rb_define_method(cMysql2Client, "last_id", rb_mysql_client_last_id, 0);
  rb_define_method(cMysql2Client, "affected_rows", rb_mysql_client_affected_rows, 0);
  rb_define_method(cMysql2Client, "thread_id", rb_mysql_client_thread_id, 0);
  rb_define_method(cMysql2Client, "ping", rb_mysql_client_ping, 0);
  rb_define_method(cMysql2Client, "select_db", rb_mysql_client_select_db, 1);
  rb_define_method(cMysql2Client, "more_results?", rb_mysql_client_more_results, 0);
  rb_define_method(cMysql2Client, "next_result", rb_mysql_client_next_result, 0);
  rb_define_method(cMysql2Client, "store_result", rb_mysql_client_store_result, 0);
  rb_define_method(cMysql2Client, "reconnect=", set_reconnect, 1);
  rb_define_method(cMysql2Client, "warning_count", rb_mysql_client_warning_count, 0);
  rb_define_method(cMysql2Client, "query_info_string", rb_mysql_info, 0);
#ifdef HAVE_RUBY_ENCODING_H
  rb_define_method(cMysql2Client, "encoding", rb_mysql_client_encoding, 0);
#endif

  rb_define_private_method(cMysql2Client, "connect_timeout=", set_connect_timeout, 1);
  rb_define_private_method(cMysql2Client, "read_timeout=", set_read_timeout, 1);
  rb_define_private_method(cMysql2Client, "write_timeout=", set_write_timeout, 1);
  rb_define_private_method(cMysql2Client, "local_infile=", set_local_infile, 1);
  rb_define_private_method(cMysql2Client, "charset_name=", set_charset_name, 1);
  rb_define_private_method(cMysql2Client, "ssl_set", set_ssl_options, 5);
  rb_define_private_method(cMysql2Client, "initialize_ext", initialize_ext, 0);
  rb_define_private_method(cMysql2Client, "connect", rb_connect, 7);

  sym_id              = ID2SYM(rb_intern("id"));
  sym_version         = ID2SYM(rb_intern("version"));
  sym_async           = ID2SYM(rb_intern("async"));
  sym_symbolize_keys  = ID2SYM(rb_intern("symbolize_keys"));
  sym_as              = ID2SYM(rb_intern("as"));
  sym_array           = ID2SYM(rb_intern("array"));
  sym_stream          = ID2SYM(rb_intern("stream"));

  intern_merge = rb_intern("merge");
  intern_merge_bang = rb_intern("merge!");
  intern_error_number_eql = rb_intern("error_number=");
  intern_sql_state_eql = rb_intern("sql_state=");

#ifdef CLIENT_LONG_PASSWORD
  rb_const_set(cMysql2Client, rb_intern("LONG_PASSWORD"),
      LONG2NUM(CLIENT_LONG_PASSWORD));
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
}
