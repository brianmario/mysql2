#include "mysql_ext.h"

/* MySQL::Client */
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

  GetMySQLClient(self, client);
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


/* MySQL::Result */
static VALUE rb_mysql_result_to_obj(MYSQL_RES * r) {
  VALUE obj;
  obj = Data_Wrap_Struct(cMySQLResult, 0, rb_mysql_result_free, r);
  rb_obj_call_init(obj, 0, NULL);
  return obj;
}

void rb_mysql_result_free(void * result) {
  MYSQL_RES * r = result;
  if (r) {
    mysql_free_result(r);
  }
}

static VALUE rb_mysql_result_fetch_row(VALUE self) {
  VALUE rowHash;
  MYSQL_RES * result;
  MYSQL_ROW row;
  MYSQL_FIELD * fields;
  unsigned int numFields;
  unsigned long * fieldLengths;
  unsigned int i;

  GetMySQLResult(self, result);

  row = mysql_fetch_row(result);
  if (row == NULL) {
    return Qnil;
  }

  numFields = mysql_num_fields(result);
  fieldLengths = mysql_fetch_lengths(result);
  fields = mysql_fetch_fields(result);

  rowHash = rb_hash_new();
  for (i = 0; i < numFields; i++) {
    VALUE key = rb_str_new(fields[i].name, fields[i].name_length);
    if (row[i]) {
      rb_hash_aset(rowHash, key, Qnil);
    } else {
      rb_hash_aset(rowHash, key, Qnil);
    }
  }
  return rowHash;
}

static VALUE rb_mysql_result_fetch_rows(VALUE self) {
  VALUE dataset;
  MYSQL_RES * result;
  unsigned long numRows, i;
  
  GetMySQLResult(self, result);
  
  numRows = mysql_num_rows(result);
  if (numRows == 0) {
    return Qnil;
  }
  
  dataset = rb_ary_new2(numRows);
  for (i = 0; i < numRows; i++) {
    VALUE row = rb_mysql_result_fetch_row(self);
    if (row == Qnil) {
      return Qnil;
    }
    rb_ary_store(dataset, i, row);
  }
  return dataset;
}

/* Ruby Extension initializer */
void Init_mysql_ext() {
  mMySQL = rb_define_module("MySQL");

  cMySQLClient = rb_define_class_under(mMySQL, "Client", rb_cObject);
  rb_define_singleton_method(cMySQLClient, "new", rb_mysql_client_new, 0);
  rb_define_method(cMySQLClient, "initialize", rb_mysql_client_init, 0);
  rb_define_method(cMySQLClient, "query", rb_mysql_client_query, 1);

  cMySQLResult = rb_define_class_under(mMySQL, "Result", rb_cObject);
  rb_define_method(cMySQLResult, "fetch_row", rb_mysql_result_fetch_row, 0);
  rb_define_method(cMySQLResult, "fetch_rows", rb_mysql_result_fetch_rows, 0);

#ifdef HAVE_RUBY_ENCODING_H
  utf8Encoding = rb_enc_find_index("UTF-8");
#endif
}