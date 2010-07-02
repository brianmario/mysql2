#include "mysql2_ext.h"

#define REQUIRE_OPEN_DB(_ctxt) \
  if(!_ctxt->net.vio) { \
    rb_raise(cMysql2Error, "closed MySQL connection"); \
    return Qnil; \
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

static VALUE nogvl_init(void *ptr) {
  MYSQL * client = (MYSQL *)ptr;

  /* may initialize embedded server and read /etc/services off disk */
  mysql_init(client);

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

static VALUE allocate(VALUE klass)
{
  MYSQL * client;

  return Data_Make_Struct(
      klass,
      MYSQL,
      NULL,
      rb_mysql_client_free,
      client
  );
}

/* Mysql2::Client */
static VALUE rb_mysql_client_init(int argc, VALUE * argv, VALUE self) {
  MYSQL * client;
  struct nogvl_connect_args args = {
    .host = "localhost",
    .user = NULL,
    .passwd = NULL,
    .db = NULL,
    .port = 3306,
    .unix_socket = NULL,
    .client_flag = 0
  };
  VALUE opts;
  VALUE rb_host, rb_socket, rb_port, rb_database,
        rb_username, rb_password, rb_reconnect,
        rb_connect_timeout;
  VALUE rb_ssl_client_key, rb_ssl_client_cert, rb_ssl_ca_cert,
        rb_ssl_ca_path, rb_ssl_cipher;
  char *ssl_client_key = NULL, *ssl_client_cert = NULL, *ssl_ca_cert = NULL,
       *ssl_ca_path = NULL, *ssl_cipher = NULL;
  unsigned int connect_timeout = 0;
  my_bool reconnect = 1;

  Data_Get_Struct(self, MYSQL, client);

  if (rb_scan_args(argc, argv, "01", &opts) == 1) {
    Check_Type(opts, T_HASH);

    if ((rb_host = rb_hash_aref(opts, sym_host)) != Qnil) {
      args.host = StringValuePtr(rb_host);
    }

    if ((rb_socket = rb_hash_aref(opts, sym_socket)) != Qnil) {
      args.unix_socket = StringValuePtr(rb_socket);
    }

    if ((rb_port = rb_hash_aref(opts, sym_port)) != Qnil) {
      args.port = NUM2INT(rb_port);
    }

    if ((rb_username = rb_hash_aref(opts, sym_username)) != Qnil) {
      args.user = StringValuePtr(rb_username);
    }

    if ((rb_password = rb_hash_aref(opts, sym_password)) != Qnil) {
      args.passwd = StringValuePtr(rb_password);
    }

    if ((rb_database = rb_hash_aref(opts, sym_database)) != Qnil) {
      args.db = StringValuePtr(rb_database);
    }

    if ((rb_reconnect = rb_hash_aref(opts, sym_reconnect)) != Qnil) {
      reconnect = rb_reconnect == Qfalse ? 0 : 1;
    }

    if ((rb_connect_timeout = rb_hash_aref(opts, sym_connect_timeout)) != Qnil) {
      connect_timeout = NUM2INT(rb_connect_timeout);
    }

    // SSL options
    if ((rb_ssl_client_key = rb_hash_aref(opts, sym_sslkey)) != Qnil) {
      ssl_client_key = StringValuePtr(rb_ssl_client_key);
    }

    if ((rb_ssl_client_cert = rb_hash_aref(opts, sym_sslcert)) != Qnil) {
      ssl_client_cert = StringValuePtr(rb_ssl_client_cert);
    }

    if ((rb_ssl_ca_cert = rb_hash_aref(opts, sym_sslca)) != Qnil) {
      ssl_ca_cert = StringValuePtr(rb_ssl_ca_cert);
    }

    if ((rb_ssl_ca_path = rb_hash_aref(opts, sym_sslcapath)) != Qnil) {
      ssl_ca_path = StringValuePtr(rb_ssl_ca_path);
    }

    if ((rb_ssl_cipher = rb_hash_aref(opts, sym_sslcipher)) != Qnil) {
      ssl_cipher = StringValuePtr(rb_ssl_cipher);
    }
  }

  if (rb_thread_blocking_region(nogvl_init, client, RUBY_UBF_IO, 0) == Qfalse) {
    // TODO: warning - not enough memory?
    return rb_raise_mysql2_error(client);
  }

  // set default reconnect behavior
  if (mysql_options(client, MYSQL_OPT_RECONNECT, &reconnect) != 0) {
    // TODO: warning - unable to set reconnect behavior
    rb_warn("%s\n", mysql_error(client));
  }

  // set default connection timeout behavior
  if (connect_timeout != 0 && mysql_options(client, MYSQL_OPT_CONNECT_TIMEOUT, (const char *)&connect_timeout) != 0) {
    // TODO: warning - unable to set connection timeout
    rb_warn("%s\n", mysql_error(client));
  }

  // force the encoding to utf8
  if (mysql_options(client, MYSQL_SET_CHARSET_NAME, "utf8") != 0) {
    // TODO: warning - unable to set charset
    rb_warn("%s\n", mysql_error(client));
  }

  if (ssl_ca_cert != NULL || ssl_client_key != NULL) {
    mysql_ssl_set(client, ssl_client_key, ssl_client_cert, ssl_ca_cert, ssl_ca_path, ssl_cipher);
  }

  args.mysql = client;
  if (rb_thread_blocking_region(nogvl_connect, &args, RUBY_UBF_IO, 0) == Qfalse) {
    // unable to connect
    return rb_raise_mysql2_error(client);
  }

  return self;
}

static void rb_mysql_client_free(void * ptr) {
  MYSQL * client = (MYSQL *)ptr;

  /*
   * we'll send a QUIT message to the server, but that message is more of a
   * formality than a hard requirement since the socket is getting shutdown
   * anyways, so ensure the socket write does not block our interpreter
   */
  int fd = client->net.fd;
  int flags;

  if (fd >= 0) {
    /*
     * if the socket is dead we have no chance of blocking,
     * so ignore any potential fcntl errors since they don't matter
     */
    flags = fcntl(fd, F_GETFL);
    if (flags > 0 && !(flags & O_NONBLOCK))
      fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  }

  /* It's safe to call mysql_close() on an already closed connection. */
  mysql_close(client);
  xfree(ptr);
}

static VALUE nogvl_close(void * ptr) {
  mysql_close((MYSQL *)ptr);
  return Qnil;
}

/*
 * Immediately disconnect from the server, normally the garbage collector
 * will disconnect automatically when a connection is no longer needed.
 * Explicitly closing this will free up server resources sooner than waiting
 * for the garbage collector.
 */
static VALUE rb_mysql_client_close(VALUE self) {
  MYSQL *client;

  Data_Get_Struct(self, MYSQL, client);

  REQUIRE_OPEN_DB(client);
  rb_thread_blocking_region(nogvl_close, client, RUBY_UBF_IO, 0);

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
  const char *sql = StringValuePtr(args->sql);
  long sql_len = RSTRING_LEN(args->sql);

  rv = mysql_send_query(args->mysql, sql, sql_len);

  return rv == 0 ? Qtrue : Qfalse;
}

static VALUE rb_mysql_client_query(int argc, VALUE * argv, VALUE self) {
  struct nogvl_send_query_args args;
  fd_set fdset;
  int fd, retval;
  int async = 0;
  VALUE opts;
  VALUE rb_async;

  MYSQL * client;

  if (rb_scan_args(argc, argv, "11", &args.sql, &opts) == 2) {
    if ((rb_async = rb_hash_aref(opts, sym_async)) != Qnil) {
      async = rb_async == Qtrue ? 1 : 0;
    }
  }

  Check_Type(args.sql, T_STRING);
  Data_Get_Struct(self, MYSQL, client);

  REQUIRE_OPEN_DB(client);

  args.mysql = client;
  if (rb_thread_blocking_region(nogvl_send_query, &args, RUBY_UBF_IO, 0) == Qfalse) {
    return rb_raise_mysql2_error(client);
  }

  if (!async) {
    // the below code is largely from do_mysql
    // http://github.com/datamapper/do
    fd = client->net.fd;
    for(;;) {
      FD_ZERO(&fdset);
      FD_SET(fd, &fdset);

      retval = rb_thread_select(fd + 1, &fdset, NULL, NULL, NULL);

      if (retval < 0) {
          rb_sys_fail(0);
      }

      if (retval > 0) {
          break;
      }
    }

    return rb_mysql_client_async_result(self);
  } else {
    return Qnil;
  }
}

static VALUE rb_mysql_client_escape(VALUE self, VALUE str) {
  MYSQL * client;
  VALUE newStr;
  unsigned long newLen, oldLen;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc = rb_default_internal_encoding();
#endif

  Check_Type(str, T_STRING);
  oldLen = RSTRING_LEN(str);
  char escaped[(oldLen*2)+1];

  Data_Get_Struct(self, MYSQL, client);

  REQUIRE_OPEN_DB(client);
  newLen = mysql_real_escape_string(client, escaped, StringValuePtr(str), RSTRING_LEN(str));
  if (newLen == oldLen) {
    // no need to return a new ruby string if nothing changed
    return str;
  } else {
    newStr = rb_str_new(escaped, newLen);
#ifdef HAVE_RUBY_ENCODING_H
    rb_enc_associate(newStr, utf8Encoding);
    if (default_internal_enc) {
      newStr = rb_str_export_to_enc(newStr, default_internal_enc);
    }
#endif
    return newStr;
  }
}

static VALUE rb_mysql_client_info(RB_MYSQL_UNUSED VALUE self) {
  VALUE version = rb_hash_new(), client_info;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc = rb_default_internal_encoding();
#endif

  rb_hash_aset(version, sym_id, LONG2NUM(mysql_get_client_version()));
  client_info = rb_str_new2(mysql_get_client_info());
#ifdef HAVE_RUBY_ENCODING_H
  rb_enc_associate(client_info, utf8Encoding);
  if (default_internal_enc) {
    client_info = rb_str_export_to_enc(client_info, default_internal_enc);
  }
#endif
  rb_hash_aset(version, sym_version, client_info);
  return version;
}

static VALUE rb_mysql_client_server_info(VALUE self) {
  MYSQL * client;
  VALUE version, server_info;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc = rb_default_internal_encoding();
#endif

  Data_Get_Struct(self, MYSQL, client);
  REQUIRE_OPEN_DB(client);

  version = rb_hash_new();
  rb_hash_aset(version, sym_id, LONG2FIX(mysql_get_server_version(client)));
  server_info = rb_str_new2(mysql_get_server_info(client));
#ifdef HAVE_RUBY_ENCODING_H
  rb_enc_associate(server_info, utf8Encoding);
  if (default_internal_enc) {
    server_info = rb_str_export_to_enc(server_info, default_internal_enc);
  }
#endif
  rb_hash_aset(version, sym_version, server_info);
  return version;
}

static VALUE rb_mysql_client_socket(VALUE self) {
  MYSQL * client;
  Data_Get_Struct(self, MYSQL, client);
  REQUIRE_OPEN_DB(client);
  return INT2NUM(client->net.fd);
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

/* mysql_store_result may (unlikely) read rows off the socket */
static VALUE nogvl_store_result(void *ptr) {
  MYSQL * client = ptr;
  return (VALUE)mysql_store_result(client);
}

static VALUE rb_mysql_client_async_result(VALUE self) {
  MYSQL * client;
  MYSQL_RES * result;

  Data_Get_Struct(self, MYSQL, client);

  REQUIRE_OPEN_DB(client);
  if (rb_thread_blocking_region(nogvl_read_query_result, client, RUBY_UBF_IO, 0) == Qfalse) {
    return rb_raise_mysql2_error(client);
  }

  result = (MYSQL_RES *)rb_thread_blocking_region(nogvl_store_result, client, RUBY_UBF_IO, 0);
  if (result == NULL) {
    if (mysql_field_count(client) != 0) {
      rb_raise_mysql2_error(client);
    }
    return Qnil;
  }

  return rb_mysql_result_to_obj(result);
}

static VALUE rb_mysql_client_last_id(VALUE self) {
  MYSQL * client;
  Data_Get_Struct(self, MYSQL, client);
  REQUIRE_OPEN_DB(client);
  return ULL2NUM(mysql_insert_id(client));
}

static VALUE rb_mysql_client_affected_rows(VALUE self) {
  MYSQL * client;
  Data_Get_Struct(self, MYSQL, client);
  REQUIRE_OPEN_DB(client);
  return ULL2NUM(mysql_affected_rows(client));
}

/* Mysql2::Result */
static VALUE rb_mysql_result_to_obj(MYSQL_RES * r) {
  VALUE obj;
  mysql2_result_wrapper * wrapper;
  obj = Data_Make_Struct(cMysql2Result, mysql2_result_wrapper, rb_mysql_result_mark, rb_mysql_result_free, wrapper);
  wrapper->numberOfFields = 0;
  wrapper->numberOfRows = 0;
  wrapper->lastRowProcessed = 0;
  wrapper->resultFreed = 0;
  wrapper->result = r;
  wrapper->fields = Qnil;
  wrapper->rows = Qnil;
  rb_obj_call_init(obj, 0, NULL);
  return obj;
}

/* this may be called manually or during GC */
static void rb_mysql_result_free_result(mysql2_result_wrapper * wrapper) {
  if (wrapper && wrapper->resultFreed != 1) {
    mysql_free_result(wrapper->result);
    wrapper->resultFreed = 1;
  }
}

/* this is called during GC */
static void rb_mysql_result_free(void * wrapper) {
  mysql2_result_wrapper * w = wrapper;
  /* FIXME: this may call flush_use_result, which can hit the socket */
  rb_mysql_result_free_result(w);
  xfree(wrapper);
}

static void rb_mysql_result_mark(void * wrapper) {
    mysql2_result_wrapper * w = wrapper;
    if (w) {
        rb_gc_mark(w->fields);
        rb_gc_mark(w->rows);
    }
}

static VALUE rb_mysql_result_fetch_field(mysql2_result_wrapper * wrapper, unsigned int idx, short int symbolize_keys) {
  if (wrapper->fields == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }

  VALUE rb_field = rb_ary_entry(wrapper->fields, idx);
  if (rb_field == Qnil) {
    MYSQL_FIELD *field = NULL;
  #ifdef HAVE_RUBY_ENCODING_H
    rb_encoding *default_internal_enc = rb_default_internal_encoding();
  #endif

    field = mysql_fetch_field_direct(wrapper->result, idx);
    if (symbolize_keys) {
      char buf[field->name_length+1];
      memcpy(buf, field->name, field->name_length);
      buf[field->name_length] = 0;
      rb_field = ID2SYM(rb_intern(buf));
    } else {
      rb_field = rb_str_new(field->name, field->name_length);
  #ifdef HAVE_RUBY_ENCODING_H
      rb_enc_associate(rb_field, utf8Encoding);
      if (default_internal_enc) {
        rb_field = rb_str_export_to_enc(rb_field, default_internal_enc);
      }
  #endif
    }
    rb_ary_store(wrapper->fields, idx, rb_field);
  }

  return rb_field;
}

static VALUE rb_mysql_result_fetch_fields(VALUE self) {
  mysql2_result_wrapper * wrapper;
  unsigned int i = 0;

  GetMysql2Result(self, wrapper);

  if (wrapper->fields == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }

  if (RARRAY_LEN(wrapper->fields) != wrapper->numberOfFields) {
    for (i=0; i<wrapper->numberOfFields; i++) {
      rb_mysql_result_fetch_field(wrapper, i, 0);
    }
  }

  return wrapper->fields;
}

/*
 * for small results, this won't hit the network, but there's no
 * reliable way for us to tell this so we'll always release the GVL
 * to be safe
 */
static VALUE nogvl_fetch_row(void *ptr) {
  MYSQL_RES *result = ptr;

  return (VALUE)mysql_fetch_row(result);
}

static VALUE rb_mysql_result_fetch_row(int argc, VALUE * argv, VALUE self) {
  VALUE rowHash, opts, block;
  mysql2_result_wrapper * wrapper;
  MYSQL_ROW row;
  MYSQL_FIELD * fields = NULL;
  unsigned int i = 0, symbolizeKeys = 0;
  unsigned long * fieldLengths;
  void * ptr;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc = rb_default_internal_encoding();
#endif

  GetMysql2Result(self, wrapper);

  if (rb_scan_args(argc, argv, "01&", &opts, &block) == 1) {
    Check_Type(opts, T_HASH);
    if (rb_hash_aref(opts, sym_symbolize_keys) == Qtrue) {
        symbolizeKeys = 1;
    }
  }

  ptr = wrapper->result;
  row = (MYSQL_ROW)rb_thread_blocking_region(nogvl_fetch_row, ptr, RUBY_UBF_IO, 0);
  if (row == NULL) {
    return Qnil;
  }

  rowHash = rb_hash_new();
  fields = mysql_fetch_fields(wrapper->result);
  fieldLengths = mysql_fetch_lengths(wrapper->result);
  if (wrapper->fields == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }

  for (i = 0; i < wrapper->numberOfFields; i++) {
    VALUE field = rb_mysql_result_fetch_field(wrapper, i, symbolizeKeys);
    if (row[i]) {
      VALUE val;
      switch(fields[i].type) {
        case MYSQL_TYPE_NULL:       // NULL-type field
          val = Qnil;
          break;
        case MYSQL_TYPE_BIT:        // BIT field (MySQL 5.0.3 and up)
          val = rb_str_new(row[i], fieldLengths[i]);
          break;
        case MYSQL_TYPE_TINY:       // TINYINT field
        case MYSQL_TYPE_SHORT:      // SMALLINT field
        case MYSQL_TYPE_LONG:       // INTEGER field
        case MYSQL_TYPE_INT24:      // MEDIUMINT field
        case MYSQL_TYPE_LONGLONG:   // BIGINT field
        case MYSQL_TYPE_YEAR:       // YEAR field
          val = rb_cstr2inum(row[i], 10);
          break;
        case MYSQL_TYPE_DECIMAL:    // DECIMAL or NUMERIC field
        case MYSQL_TYPE_NEWDECIMAL: // Precision math DECIMAL or NUMERIC field (MySQL 5.0.3 and up)
          val = rb_funcall(cBigDecimal, intern_new, 1, rb_str_new(row[i], fieldLengths[i]));
          break;
        case MYSQL_TYPE_FLOAT:      // FLOAT field
        case MYSQL_TYPE_DOUBLE:     // DOUBLE or REAL field
          val = rb_float_new(strtod(row[i], NULL));
          break;
        case MYSQL_TYPE_TIME: {     // TIME field
          int hour, min, sec, tokens;
          tokens = sscanf(row[i], "%2d:%2d:%2d", &hour, &min, &sec);
          val = rb_funcall(rb_cTime, intern_utc, 6, INT2NUM(0), INT2NUM(1), INT2NUM(1), INT2NUM(hour), INT2NUM(min), INT2NUM(sec));
          break;
        }
        case MYSQL_TYPE_TIMESTAMP:  // TIMESTAMP field
        case MYSQL_TYPE_DATETIME: { // DATETIME field
          int year, month, day, hour, min, sec, tokens;
          tokens = sscanf(row[i], "%4d-%2d-%2d %2d:%2d:%2d", &year, &month, &day, &hour, &min, &sec);
          if (year+month+day+hour+min+sec == 0) {
            val = Qnil;
          } else {
            if (month < 1 || day < 1) {
              rb_raise(cMysql2Error, "Invalid date: %s", row[i]);
              val = Qnil;
            } else {
              val = rb_funcall(rb_cTime, intern_utc, 6, INT2NUM(year), INT2NUM(month), INT2NUM(day), INT2NUM(hour), INT2NUM(min), INT2NUM(sec));
            }
          }
          break;
        }
        case MYSQL_TYPE_DATE:       // DATE field
        case MYSQL_TYPE_NEWDATE: {  // Newer const used > 5.0
          int year, month, day, tokens;
          tokens = sscanf(row[i], "%4d-%2d-%2d", &year, &month, &day);
          if (year+month+day == 0) {
            val = Qnil;
          } else {
            if (month < 1 || day < 1) {
              rb_raise(cMysql2Error, "Invalid date: %s", row[i]);
              val = Qnil;
            } else {
              val = rb_funcall(cDate, intern_new, 3, INT2NUM(year), INT2NUM(month), INT2NUM(day));
            }
          }
          break;
        }
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB:
        case MYSQL_TYPE_VAR_STRING:
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_STRING:     // CHAR or BINARY field
        case MYSQL_TYPE_SET:        // SET field
        case MYSQL_TYPE_ENUM:       // ENUM field
        case MYSQL_TYPE_GEOMETRY:   // Spatial fielda
        default:
          val = rb_str_new(row[i], fieldLengths[i]);
#ifdef HAVE_RUBY_ENCODING_H
          // rudimentary check for binary content
          if ((fields[i].flags & BINARY_FLAG) || fields[i].charsetnr == 63) {
            rb_enc_associate(val, binaryEncoding);
          } else {
            rb_enc_associate(val, utf8Encoding);
            if (default_internal_enc) {
              val = rb_str_export_to_enc(val, default_internal_enc);
            }
          }
#endif
          break;
      }
      rb_hash_aset(rowHash, field, val);
    } else {
      rb_hash_aset(rowHash, field, Qnil);
    }
  }
  return rowHash;
}

static VALUE rb_mysql_result_each(int argc, VALUE * argv, VALUE self) {
  VALUE opts, block;
  mysql2_result_wrapper * wrapper;
  unsigned long i;

  GetMysql2Result(self, wrapper);

  rb_scan_args(argc, argv, "01&", &opts, &block);

  if (wrapper->lastRowProcessed == 0) {
    wrapper->numberOfRows = mysql_num_rows(wrapper->result);
    if (wrapper->numberOfRows == 0) {
      return Qnil;
    }
    wrapper->rows = rb_ary_new2(wrapper->numberOfRows);
  }

  if (wrapper->lastRowProcessed == wrapper->numberOfRows) {
    // we've already read the entire dataset from the C result into our
    // internal array. Lets hand that over to the user since it's ready to go
    for (i = 0; i < wrapper->numberOfRows; i++) {
      rb_yield(rb_ary_entry(wrapper->rows, i));
    }
  } else {
    unsigned long rowsProcessed = 0;
    rowsProcessed = RARRAY_LEN(wrapper->rows);
    for (i = 0; i < wrapper->numberOfRows; i++) {
      VALUE row;
      if (i < rowsProcessed) {
        row = rb_ary_entry(wrapper->rows, i);
      } else {
        row = rb_mysql_result_fetch_row(argc, argv, self);
        rb_ary_store(wrapper->rows, i, row);
        wrapper->lastRowProcessed++;
      }

      if (row == Qnil) {
        // we don't need the mysql C dataset around anymore, peace it
        rb_mysql_result_free_result(wrapper);
        return Qnil;
      }

      if (block != Qnil) {
        rb_yield(row);
      }
    }
    if (wrapper->lastRowProcessed == wrapper->numberOfRows) {
      // we don't need the mysql C dataset around anymore, peace it
      rb_mysql_result_free_result(wrapper);
    }
  }

  return wrapper->rows;
}

static VALUE rb_raise_mysql2_error(MYSQL *client) {
  VALUE e = rb_exc_new2(cMysql2Error, mysql_error(client));
  rb_funcall(e, rb_intern("error_number="), 1, INT2NUM(mysql_errno(client)));
  rb_funcall(e, rb_intern("sql_state="), 1, rb_tainted_str_new2(mysql_sqlstate(client)));
  rb_exc_raise(e);
  return Qnil;
}

/* Ruby Extension initializer */
void Init_mysql2() {
  cBigDecimal = rb_const_get(rb_cObject, rb_intern("BigDecimal"));
  cDate = rb_const_get(rb_cObject, rb_intern("Date"));
  cDateTime = rb_const_get(rb_cObject, rb_intern("DateTime"));

  VALUE mMysql2 = rb_define_module("Mysql2");
  VALUE cMysql2Client = rb_define_class_under(mMysql2, "Client", rb_cObject);

  rb_define_alloc_func(cMysql2Client, allocate);

  rb_define_method(cMysql2Client, "initialize", rb_mysql_client_init, -1);
  rb_define_method(cMysql2Client, "close", rb_mysql_client_close, 0);
  rb_define_method(cMysql2Client, "query", rb_mysql_client_query, -1);
  rb_define_method(cMysql2Client, "escape", rb_mysql_client_escape, 1);
  rb_define_method(cMysql2Client, "info", rb_mysql_client_info, 0);
  rb_define_method(cMysql2Client, "server_info", rb_mysql_client_server_info, 0);
  rb_define_method(cMysql2Client, "socket", rb_mysql_client_socket, 0);
  rb_define_method(cMysql2Client, "async_result", rb_mysql_client_async_result, 0);
  rb_define_method(cMysql2Client, "last_id", rb_mysql_client_last_id, 0);
  rb_define_method(cMysql2Client, "affected_rows", rb_mysql_client_affected_rows, 0);

  cMysql2Error = rb_const_get(mMysql2, rb_intern("Error"));

  cMysql2Result = rb_define_class_under(mMysql2, "Result", rb_cObject);
  rb_define_method(cMysql2Result, "each", rb_mysql_result_each, -1);
  rb_define_method(cMysql2Result, "fields", rb_mysql_result_fetch_fields, 0);

  VALUE mEnumerable = rb_const_get(rb_cObject, rb_intern("Enumerable"));
  rb_include_module(cMysql2Result, mEnumerable);

  intern_new = rb_intern("new");
  intern_utc = rb_intern("utc");

  sym_symbolize_keys = ID2SYM(rb_intern("symbolize_keys"));
  sym_reconnect = ID2SYM(rb_intern("reconnect"));
  sym_database = ID2SYM(rb_intern("database"));
  sym_username = ID2SYM(rb_intern("username"));
  sym_password = ID2SYM(rb_intern("password"));
  sym_host = ID2SYM(rb_intern("host"));
  sym_port = ID2SYM(rb_intern("port"));
  sym_socket = ID2SYM(rb_intern("socket"));
  sym_connect_timeout = ID2SYM(rb_intern("connect_timeout"));
  sym_id = ID2SYM(rb_intern("id"));
  sym_version = ID2SYM(rb_intern("version"));
  sym_sslkey = ID2SYM(rb_intern("sslkey"));
  sym_sslcert = ID2SYM(rb_intern("sslcert"));
  sym_sslca = ID2SYM(rb_intern("sslca"));
  sym_sslcapath = ID2SYM(rb_intern("sslcapath"));
  sym_sslcipher = ID2SYM(rb_intern("sslcipher"));
  sym_async = ID2SYM(rb_intern("async"));

#ifdef HAVE_RUBY_ENCODING_H
  utf8Encoding = rb_utf8_encoding();
  binaryEncoding = rb_enc_find("binary");
#endif
}
