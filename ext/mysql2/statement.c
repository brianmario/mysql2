#include <mysql2_ext.h>

VALUE cMysql2Statement;
extern VALUE mMysql2, cMysql2Error, cBigDecimal, cDateTime, cDate;
static VALUE sym_stream, intern_error_number_eql, intern_sql_state_eql, intern_dup, intern_each;

#define GET_STATEMENT(self) \
  mysql_stmt_wrapper *stmt_wrapper; \
  Data_Get_Struct(self, mysql_stmt_wrapper, stmt_wrapper)

static void rb_mysql_stmt_mark(void * ptr) {
  mysql_stmt_wrapper* stmt_wrapper = (mysql_stmt_wrapper *)ptr;
  if(! stmt_wrapper) return;
  
  rb_gc_mark(stmt_wrapper->client);
}

static void rb_mysql_stmt_free(void * ptr) {
  mysql_stmt_wrapper* stmt_wrapper = (mysql_stmt_wrapper *)ptr;
  
  mysql_stmt_close(stmt_wrapper->stmt);

  xfree(ptr);
}

VALUE rb_raise_mysql2_stmt_error2(MYSQL_STMT *stmt
#ifdef HAVE_RUBY_ENCODING_H
  , rb_encoding *conn_enc
#endif
  ) {
  VALUE rb_error_msg = rb_str_new2(mysql_stmt_error(stmt));
  VALUE rb_sql_state = rb_tainted_str_new2(mysql_stmt_sqlstate(stmt));
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc = rb_default_internal_encoding();

  rb_enc_associate(rb_error_msg, conn_enc);
  rb_enc_associate(rb_sql_state, conn_enc);
  if (default_internal_enc) {
    rb_error_msg = rb_str_export_to_enc(rb_error_msg, default_internal_enc);
    rb_sql_state = rb_str_export_to_enc(rb_sql_state, default_internal_enc);
  }
#endif

  VALUE e = rb_exc_new3(cMysql2Error, rb_error_msg);
  rb_funcall(e, intern_error_number_eql, 1, UINT2NUM(mysql_stmt_errno(stmt)));
  rb_funcall(e, intern_sql_state_eql, 1, rb_sql_state);
  rb_exc_raise(e);
  return Qnil;
}

static void rb_raise_mysql2_stmt_error(VALUE self) {
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *conn_enc;
#endif
  GET_STATEMENT(self);
  {
    GET_CLIENT(stmt_wrapper->client);
    conn_enc = rb_to_encoding(wrapper->encoding);
  }

  rb_raise_mysql2_stmt_error2(stmt_wrapper->stmt
#ifdef HAVE_RUBY_ENCODING_H
  , conn_enc
#endif
  );
}

/*
 * used to pass all arguments to mysql_stmt_prepare while inside
 * rb_thread_blocking_region
 */
struct nogvl_prepare_statement_args {
  MYSQL_STMT *stmt;
  VALUE sql;
  const char *sql_ptr;
  unsigned long sql_len;
};

static VALUE nogvl_prepare_statement(void *ptr) {
  struct nogvl_prepare_statement_args *args = ptr;

  if (mysql_stmt_prepare(args->stmt, args->sql_ptr, args->sql_len)) {
    return Qfalse;
  } else {
    return Qtrue;
  }
}

VALUE rb_mysql_stmt_new(VALUE rb_client, VALUE sql) {
  mysql_stmt_wrapper* stmt_wrapper;
  VALUE rb_stmt;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *conn_enc;
#endif
  
  Check_Type(sql, T_STRING);

  rb_stmt = Data_Make_Struct(cMysql2Statement, mysql_stmt_wrapper, rb_mysql_stmt_mark, rb_mysql_stmt_free, stmt_wrapper);
  {
    stmt_wrapper->client = rb_client;
    stmt_wrapper->stmt = NULL;
  }

  // instantiate stmt
  {
    GET_CLIENT(rb_client);
    stmt_wrapper->stmt = mysql_stmt_init(wrapper->client);
#ifdef HAVE_RUBY_ENCODING_H
	conn_enc = rb_to_encoding(wrapper->encoding);
#endif
  }
  if (stmt_wrapper->stmt == NULL) {
    rb_raise(cMysql2Error, "Unable to initialize prepared statement: out of memory");
  }

  // set STMT_ATTR_UPDATE_MAX_LENGTH attr
  {
    my_bool truth = 1;
    if (mysql_stmt_attr_set(stmt_wrapper->stmt, STMT_ATTR_UPDATE_MAX_LENGTH, &truth)) {
      rb_raise(cMysql2Error, "Unable to initialize prepared statement: set STMT_ATTR_UPDATE_MAX_LENGTH");
    }
  }

  // call mysql_stmt_prepare w/o gvl
  {
    struct nogvl_prepare_statement_args args;
    args.stmt = stmt_wrapper->stmt;
	  args.sql = sql;
#ifdef HAVE_RUBY_ENCODING_H
	// ensure the string is in the encoding the connection is expecting
    args.sql = rb_str_export_to_enc(args.sql, conn_enc);
#endif
    args.sql_ptr = StringValuePtr(sql);
    args.sql_len = RSTRING_LEN(sql);

    if (rb_thread_blocking_region(nogvl_prepare_statement, &args, RUBY_UBF_IO, 0) == Qfalse) {
      rb_raise_mysql2_stmt_error(rb_stmt);
    }
  }

  return rb_stmt;
}

/* call-seq: stmt.param_count # => 2
 *
 * Returns the number of parameters the prepared statement expects.
 */
static VALUE param_count(VALUE self) {
  GET_STATEMENT(self);

  return ULL2NUM(mysql_stmt_param_count(stmt_wrapper->stmt));
}

/* call-seq: stmt.field_count # => 2
 *
 * Returns the number of fields the prepared statement returns.
 */
static VALUE field_count(VALUE self) {
  GET_STATEMENT(self);

  return UINT2NUM(mysql_stmt_field_count(stmt_wrapper->stmt));
}

static VALUE nogvl_execute(void *ptr) {
  MYSQL_STMT *stmt = ptr;

  if(mysql_stmt_execute(stmt)) {
    return Qfalse;
  } else {
    return Qtrue;
  }
}

static VALUE nogvl_stmt_store_result(void *ptr) {
  MYSQL_STMT *stmt = ptr;
 
  if(mysql_stmt_store_result(stmt)) {
    return Qfalse;
  } else {
    return Qtrue;
  }
}

#define FREE_BINDS                                        \
 for (i = 0; i < argc; i++) {                             \
   if (bind_buffers[i].buffer && NIL_P(params_enc[i])) {  \
     xfree(bind_buffers[i].buffer);                       \
   }                                                      \
 }                                                        \
 if(argc > 0) xfree(bind_buffers);

/* call-seq: stmt.execute
 *
 * Executes the current prepared statement, returns +result+.
 */
static VALUE execute(int argc, VALUE *argv, VALUE self) {
  MYSQL_BIND *bind_buffers = NULL;
  unsigned long bind_count;
  long i;
  MYSQL_STMT *stmt;
  MYSQL_RES *metadata;
  VALUE resultObj;
  VALUE *params_enc = alloca(sizeof(VALUE) * argc);
  unsigned long* length_buffers = NULL;
  int is_streaming = 0;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *conn_enc;
#endif
  GET_STATEMENT(self);
#ifdef HAVE_RUBY_ENCODING_H
  {
    GET_CLIENT(stmt_wrapper->client);
    conn_enc = rb_to_encoding(wrapper->encoding);
  }
#endif
  {
    VALUE valStreaming = rb_hash_aref(rb_iv_get(stmt_wrapper->client, "@query_options"), sym_stream);
    if(valStreaming == Qtrue) {
      is_streaming = 1;
    }
  }
  
  stmt = stmt_wrapper->stmt;
  
  bind_count = mysql_stmt_param_count(stmt);
  if (argc != (long)bind_count) {
    rb_raise(cMysql2Error, "Bind parameter count (%ld) doesn't match number of arguments (%d)", bind_count, argc);
  }

  // setup any bind variables in the query
  if (bind_count > 0) {
    bind_buffers = xcalloc(bind_count, sizeof(MYSQL_BIND));
    length_buffers = xcalloc(bind_count, sizeof(unsigned long));

    for (i = 0; i < argc; i++) {
      bind_buffers[i].buffer = NULL;
      params_enc[i] = Qnil;

      switch (TYPE(argv[i])) {
        case T_NIL:
          bind_buffers[i].buffer_type = MYSQL_TYPE_NULL;
          break;
        case T_FIXNUM:
#if SIZEOF_INT < SIZEOF_LONG
          bind_buffers[i].buffer_type = MYSQL_TYPE_LONGLONG;
          bind_buffers[i].buffer = malloc(sizeof(long long int));
          *(long*)(bind_buffers[i].buffer) = FIX2LONG(argv[i]);
#else
          bind_buffers[i].buffer_type = MYSQL_TYPE_LONG;
          bind_buffers[i].buffer = malloc(sizeof(int));
          *(long*)(bind_buffers[i].buffer) = FIX2INT(argv[i]);
#endif
          break;
        case T_BIGNUM:
          bind_buffers[i].buffer_type = MYSQL_TYPE_LONGLONG;
          bind_buffers[i].buffer = malloc(sizeof(long long int));
          *(LONG_LONG*)(bind_buffers[i].buffer) = rb_big2ll(argv[i]);
          break;
        case T_FLOAT:
          bind_buffers[i].buffer_type = MYSQL_TYPE_DOUBLE;
          bind_buffers[i].buffer = malloc(sizeof(double));
          *(double*)(bind_buffers[i].buffer) = NUM2DBL(argv[i]);
          break;
        case T_STRING:
          {
            params_enc[i] = rb_str_export_to_enc(argv[i], conn_enc);  
            bind_buffers[i].buffer_type = MYSQL_TYPE_STRING;
            bind_buffers[i].buffer = RSTRING_PTR(params_enc[i]);
            bind_buffers[i].buffer_length = RSTRING_LEN(params_enc[i]);
            length_buffers[i] = bind_buffers[i].buffer_length;
            bind_buffers[i].length = &length_buffers[i];
          }
          break;
        default:
          // TODO: what Ruby type should support MYSQL_TYPE_TIME
          if (CLASS_OF(argv[i]) == rb_cTime || CLASS_OF(argv[i]) == cDateTime) {
            bind_buffers[i].buffer_type = MYSQL_TYPE_DATETIME;
            bind_buffers[i].buffer = malloc(sizeof(MYSQL_TIME));

            MYSQL_TIME t;
            VALUE rb_time = argv[i];
            memset(&t, 0, sizeof(MYSQL_TIME));
            t.second_part = 0;
            t.neg = 0;
            t.second = FIX2INT(rb_funcall(rb_time, rb_intern("sec"), 0));
            t.minute = FIX2INT(rb_funcall(rb_time, rb_intern("min"), 0));
            t.hour = FIX2INT(rb_funcall(rb_time, rb_intern("hour"), 0));
            t.day = FIX2INT(rb_funcall(rb_time, rb_intern("day"), 0));
            t.month = FIX2INT(rb_funcall(rb_time, rb_intern("month"), 0));
            t.year = FIX2INT(rb_funcall(rb_time, rb_intern("year"), 0));

            *(MYSQL_TIME*)(bind_buffers[i].buffer) = t;
          } else if (CLASS_OF(argv[i]) == cDate) {
            bind_buffers[i].buffer_type = MYSQL_TYPE_NEWDATE;
            bind_buffers[i].buffer = malloc(sizeof(MYSQL_TIME));

            MYSQL_TIME t;
            VALUE rb_time = argv[i];
            memset(&t, 0, sizeof(MYSQL_TIME));
            t.second_part = 0;
            t.neg = 0;
            t.day = FIX2INT(rb_funcall(rb_time, rb_intern("day"), 0));
            t.month = FIX2INT(rb_funcall(rb_time, rb_intern("month"), 0));
            t.year = FIX2INT(rb_funcall(rb_time, rb_intern("year"), 0));

            *(MYSQL_TIME*)(bind_buffers[i].buffer) = t;
          } else if (CLASS_OF(argv[i]) == cBigDecimal) {
            bind_buffers[i].buffer_type = MYSQL_TYPE_NEWDECIMAL;
          }
          break;
      }
    }

    // copies bind_buffers into internal storage
    if (mysql_stmt_bind_param(stmt, bind_buffers)) {
      FREE_BINDS;
      rb_raise_mysql2_stmt_error(self);
    }
  }
 
  rb_mysql_client_set_active_thread(stmt_wrapper->client);
  if (rb_thread_blocking_region(nogvl_execute, stmt, RUBY_UBF_IO, 0) == Qfalse) {
    FREE_BINDS;
    rb_raise_mysql2_stmt_error(self);
  }

  FREE_BINDS;

  metadata = mysql_stmt_result_metadata(stmt);
  if(metadata == NULL) {
    if(mysql_stmt_errno(stmt) != 0) {
      // either CR_OUT_OF_MEMORY or CR_UNKNOWN_ERROR. both fatal.
	  
      MARK_CONN_INACTIVE(stmt_wrapper->client);
      rb_raise_mysql2_stmt_error(self);
    }
    // no data and no error, so query was not a SELECT
    return Qnil;
  }
  
  if(! is_streaming) {
    // recieve the whole result set from ther server
    if (rb_thread_blocking_region(nogvl_stmt_store_result, stmt, RUBY_UBF_IO, 0) == Qfalse) {
      rb_raise_mysql2_stmt_error(self);
    }
    MARK_CONN_INACTIVE(stmt_wrapper->client);
  }
  
  resultObj = rb_mysql_result_to_obj(metadata, stmt);
  rb_iv_set(resultObj, "@query_options", rb_funcall(rb_iv_get(stmt_wrapper->client, "@query_options"), intern_dup, 0));
#ifdef HAVE_RUBY_ENCODING_H
  {
    mysql2_result_wrapper* result_wrapper;

    GET_CLIENT(stmt_wrapper->client);
    GetMysql2Result(resultObj, result_wrapper);
    result_wrapper->encoding = wrapper->encoding;
  }
#endif
  
  if(! is_streaming) {
    // cache all result
    rb_funcall(resultObj, intern_each, 0);
  }

  return resultObj;
}

/* call-seq: stmt.fields # => array
 *
 * Returns a list of fields that will be returned by this statement.
 */
static VALUE fields(VALUE self) {
  MYSQL_FIELD *fields;
  MYSQL_RES *metadata;
  unsigned int field_count;
  unsigned int i;
  VALUE field_list;
  MYSQL_STMT* stmt;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *default_internal_enc, *conn_enc;
#endif
  GET_STATEMENT(self);
  stmt = stmt_wrapper->stmt;
  
#ifdef HAVE_RUBY_ENCODING_H
  default_internal_enc = rb_default_internal_encoding();
  {
    GET_CLIENT(stmt_wrapper->client);     
    conn_enc = rb_to_encoding(wrapper->encoding);
  }
#endif

  metadata    = mysql_stmt_result_metadata(stmt);
  fields      = mysql_fetch_fields(metadata);
  field_count = mysql_stmt_field_count(stmt);
  field_list  = rb_ary_new2((long)field_count);

  for(i = 0; i < field_count; i++) {
    VALUE rb_field;

    rb_field = rb_str_new(fields[i].name, fields[i].name_length);
#ifdef HAVE_RUBY_ENCODING_H
    rb_enc_associate(rb_field, conn_enc);
    if (default_internal_enc) {
	    rb_field = rb_str_export_to_enc(rb_field, default_internal_enc);
	  }
#endif

    rb_ary_store(field_list, (long)i, rb_field);
  }

  return field_list;
}

void init_mysql2_statement() {
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);

  rb_define_method(cMysql2Statement, "param_count", param_count, 0);
  rb_define_method(cMysql2Statement, "field_count", field_count, 0);
  rb_define_method(cMysql2Statement, "execute", execute, -1);
  rb_define_method(cMysql2Statement, "fields", fields, 0);
  
  sym_stream = ID2SYM(rb_intern("stream"));
  
  intern_error_number_eql = rb_intern("error_number=");
  intern_sql_state_eql = rb_intern("sql_state=");
  intern_dup = rb_intern("dup");
  intern_each = rb_intern("each");
}
