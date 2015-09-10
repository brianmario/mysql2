#include <mysql2_ext.h>

VALUE cMysql2Statement;
extern VALUE mMysql2, cMysql2Error, cBigDecimal, cDateTime, cDate;
static VALUE sym_stream, intern_new_with_args, intern_each;
static VALUE intern_usec, intern_sec, intern_min, intern_hour, intern_day, intern_month, intern_year;

#define GET_STATEMENT(self) \
  mysql_stmt_wrapper *stmt_wrapper; \
  Data_Get_Struct(self, mysql_stmt_wrapper, stmt_wrapper);


static void rb_mysql_stmt_mark(void * ptr) {
  mysql_stmt_wrapper* stmt_wrapper = (mysql_stmt_wrapper *)ptr;
  if (!stmt_wrapper) return;

  rb_gc_mark(stmt_wrapper->client);
}

static void rb_mysql_stmt_free(void * ptr) {
  mysql_stmt_wrapper* stmt_wrapper = (mysql_stmt_wrapper *)ptr;
  decr_mysql2_stmt(stmt_wrapper);
}

void decr_mysql2_stmt(mysql_stmt_wrapper *stmt_wrapper) {
  stmt_wrapper->refcount--;

  if (stmt_wrapper->refcount == 0) {
    mysql_stmt_close(stmt_wrapper->stmt);
    xfree(stmt_wrapper);
  }
}


void rb_raise_mysql2_stmt_error(mysql_stmt_wrapper *stmt_wrapper) {
  VALUE e;
  GET_CLIENT(stmt_wrapper->client);
  VALUE rb_error_msg = rb_str_new2(mysql_stmt_error(stmt_wrapper->stmt));
  VALUE rb_sql_state = rb_tainted_str_new2(mysql_stmt_sqlstate(stmt_wrapper->stmt));

#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *conn_enc;
  conn_enc = rb_to_encoding(wrapper->encoding);

  rb_encoding *default_internal_enc = rb_default_internal_encoding();

  rb_enc_associate(rb_error_msg, conn_enc);
  rb_enc_associate(rb_sql_state, conn_enc);
  if (default_internal_enc) {
    rb_error_msg = rb_str_export_to_enc(rb_error_msg, default_internal_enc);
    rb_sql_state = rb_str_export_to_enc(rb_sql_state, default_internal_enc);
  }
#endif

  e = rb_funcall(cMysql2Error, intern_new_with_args, 4,
                 rb_error_msg,
                 LONG2FIX(wrapper->server_version),
                 UINT2NUM(mysql_stmt_errno(stmt_wrapper->stmt)),
                 rb_sql_state);
  rb_exc_raise(e);
}


/*
 * used to pass all arguments to mysql_stmt_prepare while inside
 * nogvl_prepare_statement_args
 */
struct nogvl_prepare_statement_args {
  MYSQL_STMT *stmt;
  VALUE sql;
  const char *sql_ptr;
  unsigned long sql_len;
};

static void *nogvl_prepare_statement(void *ptr) {
  struct nogvl_prepare_statement_args *args = ptr;

  if (mysql_stmt_prepare(args->stmt, args->sql_ptr, args->sql_len)) {
    return (void*)Qfalse;
  } else {
    return (void*)Qtrue;
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
    stmt_wrapper->refcount = 1;
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
    args.sql_ptr = RSTRING_PTR(sql);
    args.sql_len = RSTRING_LEN(sql);

    if ((VALUE)rb_thread_call_without_gvl(nogvl_prepare_statement, &args, RUBY_UBF_IO, 0) == Qfalse) {
      rb_raise_mysql2_stmt_error(stmt_wrapper);
    }
  }

  return rb_stmt;
}

/* call-seq: stmt.param_count # => Numeric
 *
 * Returns the number of parameters the prepared statement expects.
 */
static VALUE param_count(VALUE self) {
  GET_STATEMENT(self);

  return ULL2NUM(mysql_stmt_param_count(stmt_wrapper->stmt));
}

/* call-seq: stmt.field_count # => Numeric
 *
 * Returns the number of fields the prepared statement returns.
 */
static VALUE field_count(VALUE self) {
  GET_STATEMENT(self);

  return UINT2NUM(mysql_stmt_field_count(stmt_wrapper->stmt));
}

static void *nogvl_execute(void *ptr) {
  MYSQL_STMT *stmt = ptr;

  if (mysql_stmt_execute(stmt)) {
    return (void*)Qfalse;
  } else {
    return (void*)Qtrue;
  }
}

static void *nogvl_stmt_store_result(void *ptr) {
  MYSQL_STMT *stmt = ptr;

  if (mysql_stmt_store_result(stmt)) {
    return (void *)Qfalse;
  } else {
    return (void *)Qtrue;
  }
}

/* Free each bind_buffer[i].buffer except when params_enc is non-nil, this means
 * the buffer is a Ruby string pointer and not our memory to manage.
 */
#define FREE_BINDS                                          \
  for (i = 0; i < argc; i++) {                              \
    if (bind_buffers[i].buffer && NIL_P(params_enc[i])) {   \
      xfree(bind_buffers[i].buffer);                        \
    }                                                       \
  }                                                         \
  if (argc > 0) {                                           \
    xfree(bind_buffers);                                    \
    xfree(length_buffers);                                  \
  }

/* call-seq: stmt.execute
 *
 * Executes the current prepared statement, returns +result+.
 */
static VALUE execute(int argc, VALUE *argv, VALUE self) {
  MYSQL_BIND *bind_buffers = NULL;
  unsigned long *length_buffers = NULL;
  unsigned long bind_count;
  long i;
  MYSQL_STMT *stmt;
  MYSQL_RES *metadata;
  VALUE current;
  VALUE resultObj;
  VALUE *params_enc;
  int is_streaming;
#ifdef HAVE_RUBY_ENCODING_H
  rb_encoding *conn_enc;
#endif

  GET_STATEMENT(self);
  GET_CLIENT(stmt_wrapper->client);

#ifdef HAVE_RUBY_ENCODING_H
  conn_enc = rb_to_encoding(wrapper->encoding);
#endif

  /* Scratch space for string encoding exports, allocate on the stack. */
  params_enc = alloca(sizeof(VALUE) * argc);

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
          bind_buffers[i].buffer = xmalloc(sizeof(long long int));
          *(long*)(bind_buffers[i].buffer) = FIX2LONG(argv[i]);
#else
          bind_buffers[i].buffer_type = MYSQL_TYPE_LONG;
          bind_buffers[i].buffer = xmalloc(sizeof(int));
          *(long*)(bind_buffers[i].buffer) = FIX2INT(argv[i]);
#endif
          break;
        case T_BIGNUM:
          bind_buffers[i].buffer_type = MYSQL_TYPE_LONGLONG;
          bind_buffers[i].buffer = xmalloc(sizeof(long long int));
          *(LONG_LONG*)(bind_buffers[i].buffer) = rb_big2ll(argv[i]);
          break;
        case T_FLOAT:
          bind_buffers[i].buffer_type = MYSQL_TYPE_DOUBLE;
          bind_buffers[i].buffer = xmalloc(sizeof(double));
          *(double*)(bind_buffers[i].buffer) = NUM2DBL(argv[i]);
          break;
        case T_STRING:
          {
            params_enc[i] = argv[i];
#ifdef HAVE_RUBY_ENCODING_H
            params_enc[i] = rb_str_export_to_enc(params_enc[i], conn_enc);
#endif
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
            MYSQL_TIME t;
            VALUE rb_time = argv[i];

            bind_buffers[i].buffer_type = MYSQL_TYPE_DATETIME;
            bind_buffers[i].buffer = xmalloc(sizeof(MYSQL_TIME));

            memset(&t, 0, sizeof(MYSQL_TIME));
            t.neg = 0;
            t.second_part = FIX2INT(rb_funcall(rb_time, intern_usec, 0));
            t.second = FIX2INT(rb_funcall(rb_time, intern_sec, 0));
            t.minute = FIX2INT(rb_funcall(rb_time, intern_min, 0));
            t.hour = FIX2INT(rb_funcall(rb_time, intern_hour, 0));
            t.day = FIX2INT(rb_funcall(rb_time, intern_day, 0));
            t.month = FIX2INT(rb_funcall(rb_time, intern_month, 0));
            t.year = FIX2INT(rb_funcall(rb_time, intern_year, 0));

            *(MYSQL_TIME*)(bind_buffers[i].buffer) = t;
          } else if (CLASS_OF(argv[i]) == cDate) {
            MYSQL_TIME t;
            VALUE rb_time = argv[i];

            bind_buffers[i].buffer_type = MYSQL_TYPE_DATE;
            bind_buffers[i].buffer = xmalloc(sizeof(MYSQL_TIME));

            memset(&t, 0, sizeof(MYSQL_TIME));
            t.second_part = 0;
            t.neg = 0;
            t.day = FIX2INT(rb_funcall(rb_time, intern_day, 0));
            t.month = FIX2INT(rb_funcall(rb_time, intern_month, 0));
            t.year = FIX2INT(rb_funcall(rb_time, intern_year, 0));

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
      rb_raise_mysql2_stmt_error(stmt_wrapper);
    }
  }

  if ((VALUE)rb_thread_call_without_gvl(nogvl_execute, stmt, RUBY_UBF_IO, 0) == Qfalse) {
    FREE_BINDS;
    rb_raise_mysql2_stmt_error(stmt_wrapper);
  }

  FREE_BINDS;

  metadata = mysql_stmt_result_metadata(stmt);
  if (metadata == NULL) {
    if (mysql_stmt_errno(stmt) != 0) {
      // either CR_OUT_OF_MEMORY or CR_UNKNOWN_ERROR. both fatal.

      MARK_CONN_INACTIVE(stmt_wrapper->client);
      rb_raise_mysql2_stmt_error(stmt_wrapper);
    }
    // no data and no error, so query was not a SELECT
    return Qnil;
  }

  current = rb_hash_dup(rb_iv_get(stmt_wrapper->client, "@query_options"));
  (void)RB_GC_GUARD(current);
  Check_Type(current, T_HASH);

  is_streaming = (Qtrue == rb_hash_aref(current, sym_stream));
  if (!is_streaming) {
    // recieve the whole result set from the server
    if (rb_thread_call_without_gvl(nogvl_stmt_store_result, stmt, RUBY_UBF_IO, 0) == Qfalse) {
      mysql_free_result(metadata);
      rb_raise_mysql2_stmt_error(stmt_wrapper);
    }
    MARK_CONN_INACTIVE(stmt_wrapper->client);
  }

  resultObj = rb_mysql_result_to_obj(stmt_wrapper->client, wrapper->encoding, current, metadata, self);

  if (!is_streaming) {
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

  mysql_free_result(metadata);
  return field_list;
}

/* call-seq:
 *    stmt.last_id
 *
 * Returns the AUTO_INCREMENT value from the executed INSERT or UPDATE.
 */
static VALUE rb_mysql_stmt_last_id(VALUE self) {
  GET_STATEMENT(self);
  return ULL2NUM(mysql_stmt_insert_id(stmt_wrapper->stmt));
}

/* call-seq:
 *    stmt.affected_rows
 *
 * Returns the number of rows changed, deleted, or inserted.
 */
static VALUE rb_mysql_stmt_affected_rows(VALUE self) {
  my_ulonglong affected;
  GET_STATEMENT(self);

  affected = mysql_stmt_affected_rows(stmt_wrapper->stmt);
  if (affected == (my_ulonglong)-1) {
    rb_raise_mysql2_stmt_error(self);
  }

  return ULL2NUM(affected);
}

void init_mysql2_statement() {
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);

  rb_define_method(cMysql2Statement, "param_count", param_count, 0);
  rb_define_method(cMysql2Statement, "field_count", field_count, 0);
  rb_define_method(cMysql2Statement, "execute", execute, -1);
  rb_define_method(cMysql2Statement, "fields", fields, 0);
  rb_define_method(cMysql2Statement, "last_id", rb_mysql_stmt_last_id, 0);
  rb_define_method(cMysql2Statement, "affected_rows", rb_mysql_stmt_affected_rows, 0);

  sym_stream = ID2SYM(rb_intern("stream"));

  intern_new_with_args = rb_intern("new_with_args");
  intern_each = rb_intern("each");

  intern_usec = rb_intern("usec");
  intern_sec = rb_intern("sec");
  intern_min = rb_intern("min");
  intern_hour = rb_intern("hour");
  intern_day = rb_intern("day");
  intern_month = rb_intern("month");
  intern_year = rb_intern("year");
}
