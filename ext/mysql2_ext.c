#include "mysql2_ext.h"

/* Mysql2::Client */
static VALUE rb_mysql_client_new(int argc, VALUE * argv, VALUE klass) {
  MYSQL * client;
  VALUE obj, opts;
  VALUE rb_host, rb_socket, rb_port, rb_database,
        rb_username, rb_password, rb_reconnect,
        rb_connect_timeout;
  char *host = "localhost", *socket = NULL, *username = NULL,
       *password = NULL, *database = NULL;
  unsigned int port = 3306, connect_timeout = 0;
  my_bool reconnect = 0;

  obj = Data_Make_Struct(klass, MYSQL, NULL, rb_mysql_client_free, client);

  if (rb_scan_args(argc, argv, "01", &opts) == 1) {
    Check_Type(opts, T_HASH);

    if ((rb_host = rb_hash_aref(opts, sym_host)) != Qnil) {
      Check_Type(rb_host, T_STRING);
      host = RSTRING_PTR(rb_host);
    }

    if ((rb_socket = rb_hash_aref(opts, sym_socket)) != Qnil) {
      Check_Type(rb_socket, T_STRING);
      socket = RSTRING_PTR(rb_socket);
    }

    if ((rb_port = rb_hash_aref(opts, sym_port)) != Qnil) {
      Check_Type(rb_port, T_FIXNUM);
      port = FIX2INT(rb_port);
    }

    if ((rb_username = rb_hash_aref(opts, sym_username)) != Qnil) {
      Check_Type(rb_username, T_STRING);
      username = RSTRING_PTR(rb_username);
    }

    if ((rb_password = rb_hash_aref(opts, sym_password)) != Qnil) {
      Check_Type(rb_password, T_STRING);
      password = RSTRING_PTR(rb_password);
    }

    if ((rb_database = rb_hash_aref(opts, sym_database)) != Qnil) {
      Check_Type(rb_database, T_STRING);
      database = RSTRING_PTR(rb_database);
    }

    if ((rb_reconnect = rb_hash_aref(opts, sym_reconnect)) != Qnil) {
      reconnect = rb_reconnect == Qtrue ? 1 : 0;
    }

    if ((rb_connect_timeout = rb_hash_aref(opts, sym_connect_timeout)) != Qnil) {
      Check_Type(rb_connect_timeout, T_FIXNUM);
      connect_timeout = FIX2INT(rb_connect_timeout);
    }
  }

  if (!mysql_init(client)) {
    // TODO: warning - not enough memory?
    rb_raise(cMysql2Error, "%s", mysql_error(client));
    return Qnil;
  }

  // set default reconnect behavior
  if (mysql_options(client, MYSQL_OPT_RECONNECT, &reconnect) != 0) {
    // TODO: warning - unable to set reconnect behavior
    rb_warn("%s\n", mysql_error(client));
  }

  // set default connection timeout behavior
  if (connect_timeout != 0 && mysql_options(client, MYSQL_OPT_CONNECT_TIMEOUT, &connect_timeout) != 0) {
    // TODO: warning - unable to set connection timeout
    rb_warn("%s\n", mysql_error(client));
  }

  // force the encoding to utf8
  if (mysql_options(client, MYSQL_SET_CHARSET_NAME, "utf8") != 0) {
    // TODO: warning - unable to set charset
    rb_warn("%s\n", mysql_error(client));
  }

  if (mysql_real_connect(client, host, username, password, database, port, socket, 0) == NULL) {
    // unable to connect
    rb_raise(cMysql2Error, "%s", mysql_error(client));
    return Qnil;
  }

  rb_obj_call_init(obj, argc, argv);
  return obj;
}

static VALUE rb_mysql_client_init(VALUE self, int argc, VALUE * argv) {
  return self;
}

void rb_mysql_client_free(void * client) {
  MYSQL * c = client;
  if (c) {
    mysql_close(client);
  }
}

static VALUE rb_mysql_client_query(VALUE self, VALUE sql) {
  MYSQL * client;
  MYSQL_RES * result;
  fd_set fdset;
  int fd, retval;
  Check_Type(sql, T_STRING);

  GetMysql2Client(self, client);
  if (mysql_send_query(client, RSTRING_PTR(sql), RSTRING_LEN(sql)) != 0) {
    rb_raise(cMysql2Error, "%s", mysql_error(client));
    return Qnil;
  }

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

  if (mysql_read_query_result(client) != 0) {
    rb_raise(cMysql2Error, "%s", mysql_error(client));
    return Qnil;
  }

  result = mysql_store_result(client);
  if (result == NULL) {
    if (mysql_field_count(client) != 0) {
      rb_raise(cMysql2Error, "%s", mysql_error(client));
    }
    return Qnil;
  }
  return rb_mysql_result_to_obj(result);
}

static VALUE rb_mysql_client_escape(VALUE self, VALUE str) {
  MYSQL * client;
  VALUE newStr;
  unsigned long newLen, oldLen;

  Check_Type(str, T_STRING);
  oldLen = RSTRING_LEN(str);
  char escaped[(oldLen*2)+1];

  GetMysql2Client(self, client);

  newLen = mysql_real_escape_string(client, escaped, RSTRING_PTR(str), RSTRING_LEN(str));
  if (newLen == oldLen) {
    // no need to return a new ruby string if nothing changed
    return str;
  } else {
    newStr = rb_str_new(escaped, newLen);
#ifdef HAVE_RUBY_ENCODING_H
    rb_enc_associate_index(newStr, utf8Encoding);
#endif
    return newStr;
  }
}

static VALUE rb_mysql_client_info(VALUE self) {
  VALUE version = rb_hash_new();
  rb_hash_aset(version, sym_id, LONG2FIX(mysql_get_client_version()));
  rb_hash_aset(version, sym_version, rb_str_new2(mysql_get_client_info()));
  return version;
}

static VALUE rb_mysql_client_server_info(VALUE self) {
  MYSQL * client;
  VALUE version;

  GetMysql2Client(self, client);
  version = rb_hash_new();
  rb_hash_aset(version, sym_id, LONG2FIX(mysql_get_server_version(client)));
  rb_hash_aset(version, sym_version, rb_str_new2(mysql_get_server_info(client)));
  return version;
}

static VALUE rb_mysql_client_socket(VALUE self) {
  MYSQL * client = GetMysql2Client(self, client);;
  return INT2NUM(client->net.fd);
}

/* Mysql2::Result */
static VALUE rb_mysql_result_to_obj(MYSQL_RES * r) {
  VALUE obj;
  obj = Data_Wrap_Struct(cMysql2Result, 0, rb_mysql_result_free, r);
  rb_obj_call_init(obj, 0, NULL);
  return obj;
}

void rb_mysql_result_free(void * result) {
  MYSQL_RES * r = result;
  if (r) {
    mysql_free_result(r);
  }
}

static VALUE rb_mysql_result_fetch_row(int argc, VALUE * argv, VALUE self) {
  VALUE rowHash, opts, block;
  MYSQL_RES * result;
  MYSQL_ROW row;
  MYSQL_FIELD * fields;
  struct tm parsedTime;
  unsigned int i = 0, numFields = 0, symbolizeKeys = 0;
  unsigned long * fieldLengths;

  GetMysql2Result(self, result);

  if (rb_scan_args(argc, argv, "01&", &opts, &block) == 1) {
    Check_Type(opts, T_HASH);
    if (rb_hash_aref(opts, sym_symbolize_keys) == Qtrue) {
        symbolizeKeys = 1;
    }
  }

  row = mysql_fetch_row(result);
  if (row == NULL) {
    return Qnil;
  }

  numFields = mysql_num_fields(result);
  fieldLengths = mysql_fetch_lengths(result);
  fields = mysql_fetch_fields(result);

  rowHash = rb_hash_new();
  for (i = 0; i < numFields; i++) {
    VALUE key;
    if (symbolizeKeys) {
      char buf[fields[i].name_length+1];
      memcpy(buf, fields[i].name, fields[i].name_length);
      buf[fields[i].name_length] = 0;
      key = ID2SYM(rb_intern(buf));
    } else {
      key = rb_str_new(fields[i].name, fields[i].name_length);
#ifdef HAVE_RUBY_ENCODING_H
      rb_enc_associate_index(key, utf8Encoding);
#endif
    }
    if (row[i]) {
      VALUE val;
      switch(fields[i].type) {
        case MYSQL_TYPE_NULL:       // NULL-type field
          val = Qnil;
          break;
        case MYSQL_TYPE_TINY:       // TINYINT field
        case MYSQL_TYPE_BIT:        // BIT field (MySQL 5.0.3 and up)
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
        case MYSQL_TYPE_TIME:       // TIME field
          if (memcmp("00:00:00", row[i], 10) == 0) {
            val = rb_str_new(row[i], fieldLengths[i]);
          } else {
            strptime(row[i], "%T", &parsedTime);
            val = rb_funcall(rb_cTime, intern_local, 6, INT2NUM(1900+parsedTime.tm_year), INT2NUM(parsedTime.tm_mon+1), INT2NUM(parsedTime.tm_mday), INT2NUM(parsedTime.tm_hour), INT2NUM(parsedTime.tm_min), INT2NUM(parsedTime.tm_sec));
          }
          break;
        case MYSQL_TYPE_TIMESTAMP:  // TIMESTAMP field
        case MYSQL_TYPE_DATETIME:   // DATETIME field
          if (memcmp("0000-00-00 00:00:00", row[i], 19) == 0) {
            val = Qnil;
          } else {
            strptime(row[i], "%F %T", &parsedTime);
            val = rb_funcall(rb_cTime, intern_local, 6, INT2NUM(1900+parsedTime.tm_year), INT2NUM(parsedTime.tm_mon+1), INT2NUM(parsedTime.tm_mday), INT2NUM(parsedTime.tm_hour), INT2NUM(parsedTime.tm_min), INT2NUM(parsedTime.tm_sec));
          }
          break;
        case MYSQL_TYPE_DATE:       // DATE field
        case MYSQL_TYPE_NEWDATE:    // Newer const used > 5.0
          if (memcmp("0000-00-00", row[i], 10) == 0) {
            val = Qnil;
          } else {
            strptime(row[i], "%F", &parsedTime);
            val = rb_funcall(rb_cTime, intern_local, 3, INT2NUM(1900+parsedTime.tm_year), INT2NUM(parsedTime.tm_mon+1), INT2NUM(parsedTime.tm_mday));
          }
          break;
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
            rb_enc_associate_index(val, binaryEncoding);
          } else {
            rb_enc_associate_index(val, utf8Encoding);
          }
#endif
          break;
      }
      rb_hash_aset(rowHash, key, val);
    } else {
      rb_hash_aset(rowHash, key, Qnil);
    }
  }
  return rowHash;
}

static VALUE rb_mysql_result_each(int argc, VALUE * argv, VALUE self) {
  VALUE dataset, opts, block;
  MYSQL_RES * result;
  unsigned long numRows, i;

  GetMysql2Result(self, result);

  rb_scan_args(argc, argv, "01&", &opts, &block);

  // force-start at the beginning of the result set for proper
  // behavior of #each
  mysql_data_seek(result, 0);

  numRows = mysql_num_rows(result);
  if (numRows == 0) {
    return Qnil;
  }

  // TODO: allow yielding datasets of configurable size
  // like find_in_batches from AR...
  if (block != Qnil) {
    for (i = 0; i < numRows; i++) {
      VALUE row = rb_mysql_result_fetch_row(argc, argv, self);
      if (row == Qnil) {
        return Qnil;
      }
      rb_yield(row);
    }
  } else {
    dataset = rb_ary_new2(numRows);
    for (i = 0; i < numRows; i++) {
      VALUE row = rb_mysql_result_fetch_row(argc, argv, self);
      if (row == Qnil) {
        return Qnil;
      }
      rb_ary_store(dataset, i, row);
    }
    return dataset;
  }
  return Qnil;
}

/* Ruby Extension initializer */
void Init_mysql2_ext() {
  rb_require("date");
  rb_require("bigdecimal");

  cBigDecimal = rb_const_get(rb_cObject, rb_intern("BigDecimal"));
  cDate = rb_const_get(rb_cObject, rb_intern("Date"));
  cDateTime = rb_const_get(rb_cObject, rb_intern("DateTime"));

  VALUE mMysql2 = rb_define_module("Mysql2");

  VALUE cMysql2Client = rb_define_class_under(mMysql2, "Client", rb_cObject);
  rb_define_singleton_method(cMysql2Client, "new", rb_mysql_client_new, -1);
  rb_define_method(cMysql2Client, "initialize", rb_mysql_client_init, -1);
  rb_define_method(cMysql2Client, "query", rb_mysql_client_query, 1);
  rb_define_method(cMysql2Client, "escape", rb_mysql_client_escape, 1);
  rb_define_method(cMysql2Client, "info", rb_mysql_client_info, 0);
  rb_define_method(cMysql2Client, "server_info", rb_mysql_client_server_info, 0);
  rb_define_method(cMysql2Client, "socket", rb_mysql_client_socket, 0);

  cMysql2Error = rb_define_class_under(mMysql2, "Error", rb_eStandardError);

  cMysql2Result = rb_define_class_under(mMysql2, "Result", rb_cObject);
  rb_define_method(cMysql2Result, "each", rb_mysql_result_each, -1);

  VALUE mEnumerable = rb_const_get(rb_cObject, rb_intern("Enumerable"));
  rb_include_module(cMysql2Result, mEnumerable);

  intern_new = rb_intern("new");
  intern_local = rb_intern("local");

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

#ifdef HAVE_RUBY_ENCODING_H
  utf8Encoding = rb_enc_find_index("UTF-8");
  binaryEncoding = rb_enc_find_index("binary");
#endif
}