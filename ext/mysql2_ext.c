#include "mysql2_ext.h"

/* Mysql2::Client */
static VALUE rb_mysql_client_new(VALUE klass) {
  MYSQL * client;
  VALUE obj;

  obj = Data_Make_Struct(klass, MYSQL, NULL, rb_mysql_client_free, client);

  if (!mysql_init(client)) {
    // TODO: warning - not enough memory?
    rb_raise(rb_eStandardError, "%s", mysql_error(client));
    return Qnil;
  }

  if (mysql_options(client, MYSQL_SET_CHARSET_NAME, "utf8") != 0) {
    // TODO: warning - unable to set charset
    rb_warn("%s", mysql_error(client));
  }

  // HACK
  if (!mysql_real_connect(client, "localhost", "root", NULL, NULL, 0, NULL, 0)) {
    // unable to connect
    rb_raise(rb_eStandardError, "%s", mysql_error(client));
    return Qnil;
  }
  // HACK

  rb_obj_call_init(obj, 0, NULL);
  return obj;
}

static VALUE rb_mysql_client_init(VALUE self) {
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
  MYSQL_RES * result = NULL;
  int query;
  Check_Type(sql, T_STRING);

  GetMysql2Client(self, client);
  query = mysql_real_query(client, RSTRING_PTR(sql), RSTRING_LEN(sql));
  if (query != 0) {
    // lookup error code and msg, raise exception
  }

  result = mysql_store_result(client);
  if (result == NULL) {
    // lookup error code and msg, raise exception
  }
  return rb_mysql_result_to_obj(result);
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
    }
    if (row[i]) {
      rb_hash_aset(rowHash, key, Qnil);
    } else {
      rb_hash_aset(rowHash, key, Qnil);
    }
  }
  return rowHash;
}

static VALUE rb_mysql_result_fetch_rows(int argc, VALUE * argv, VALUE self) {
  VALUE dataset, opts, block;
  MYSQL_RES * result;
  unsigned long numRows, i;

  GetMysql2Result(self, result);

  rb_scan_args(argc, argv, "01&", &opts, &block);

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
  mMysql2 = rb_define_module("Mysql2");

  cMysql2Client = rb_define_class_under(mMysql2, "Client", rb_cObject);
  rb_define_singleton_method(cMysql2Client, "new", rb_mysql_client_new, 0);
  rb_define_method(cMysql2Client, "initialize", rb_mysql_client_init, 0);
  rb_define_method(cMysql2Client, "query", rb_mysql_client_query, 1);

  cMysql2Result = rb_define_class_under(mMysql2, "Result", rb_cObject);
  rb_define_method(cMysql2Result, "fetch_row", rb_mysql_result_fetch_row, -1);
  rb_define_method(cMysql2Result, "fetch_rows", rb_mysql_result_fetch_rows, -1);
  rb_define_method(cMysql2Result, "each", rb_mysql_result_fetch_rows, -1);

  sym_symbolize_keys = ID2SYM(rb_intern("symbolize_keys"));

#ifdef HAVE_RUBY_ENCODING_H
  utf8Encoding = rb_enc_find_index("UTF-8");
#endif
}