#include <mysql2_ext.h>

VALUE cMysql2Statement;
extern VALUE mMysql2, cMysql2Error, cBigDecimal, cDateTime, cDate;

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
      rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt_wrapper->stmt));
    }
  }

  return rb_stmt;
}

#define GET_STATEMENT(self) \
  mysql_stmt_wrapper *stmt_wrapper; \
  Data_Get_Struct(self, mysql_stmt_wrapper, stmt_wrapper)

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

#define FREE_BINDS                  \
 for (i = 0; i < argc; i++) {       \
   if (bind_buffers[i].buffer) {    \
     free(bind_buffers[i].buffer);  \
   }                                \
 }                                  \
 free(bind_buffers);

/* call-seq: stmt.execute
 *
 * Executes the current prepared statement, returns +stmt+.
 */
static VALUE execute(int argc, VALUE *argv, VALUE self) {
  MYSQL_BIND *bind_buffers;
  unsigned long bind_count;
  long i;
  MYSQL_STMT* stmt;
  GET_STATEMENT(self);
  
  stmt = stmt_wrapper->stmt;
  
  bind_count = mysql_stmt_param_count(stmt);
  if (argc != (long)bind_count) {
    rb_raise(cMysql2Error, "Bind parameter count (%ld) doesn't match number of arguments (%d)", bind_count, argc);
  }

  // setup any bind variables in the query
  if (bind_count > 0) {
    bind_buffers = xcalloc(bind_count, sizeof(MYSQL_BIND));

    for (i = 0; i < argc; i++) {
      bind_buffers[i].buffer = NULL;

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
          // FIXME: convert encoding
          bind_buffers[i].buffer_type = MYSQL_TYPE_STRING;
          bind_buffers[i].buffer = RSTRING_PTR(argv[i]);
          bind_buffers[i].buffer_length = RSTRING_LEN(argv[i]);
          unsigned long len = RSTRING_LEN(argv[i]);
          bind_buffers[i].length = &len;
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
      rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt));
    }
  }

  if (rb_thread_blocking_region(nogvl_execute, stmt, RUBY_UBF_IO, 0) == Qfalse) {
    FREE_BINDS;
    rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt));
  }

  if (bind_count > 0) {
    FREE_BINDS;
  }

  return self;
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

static VALUE each(VALUE self) {
  MYSQL_STMT *stmt;
  MYSQL_RES *result;
  GET_STATEMENT(self);
  stmt = stmt_wrapper->stmt;
  
  if(! rb_block_given_p())
  {
    rb_raise(cMysql2Error, "FIXME: current limitation: each require block");
  }

  result = mysql_stmt_result_metadata(stmt);
  if (result) {
    MYSQL_BIND *result_buffers;
    my_bool *is_null;
    my_bool *error;
    unsigned long *length;
    MYSQL_FIELD *fields;
    unsigned long field_count;
    unsigned long i;

    if (mysql_stmt_store_result(stmt)) {
      rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt));
    }

    fields = mysql_fetch_fields(result);
    field_count = mysql_num_fields(result);

    result_buffers = xcalloc(field_count, sizeof(MYSQL_BIND));
    is_null = xcalloc(field_count, sizeof(my_bool));
    error   = xcalloc(field_count, sizeof(my_bool));
    length  = xcalloc(field_count, sizeof(unsigned long));

    for (i = 0; i < field_count; i++) {
      result_buffers[i].buffer_type = fields[i].type;

      //      mysql type    |            C type
      switch(fields[i].type) {
        case MYSQL_TYPE_NULL:         // NULL
          break;
        case MYSQL_TYPE_TINY:         // signed char
          result_buffers[i].buffer = xcalloc(1, sizeof(signed char));
          result_buffers[i].buffer_length = sizeof(signed char);
          break;
        case MYSQL_TYPE_SHORT:        // short int
          result_buffers[i].buffer = xcalloc(1, sizeof(short int));
          result_buffers[i].buffer_length = sizeof(short int);
          break;
        case MYSQL_TYPE_INT24:        // int
        case MYSQL_TYPE_LONG:         // int
        case MYSQL_TYPE_YEAR:         // int
          result_buffers[i].buffer = xcalloc(1, sizeof(int));
          result_buffers[i].buffer_length = sizeof(int);
          break;
        case MYSQL_TYPE_LONGLONG:     // long long int
          result_buffers[i].buffer = xcalloc(1, sizeof(long long int));
          result_buffers[i].buffer_length = sizeof(long long int);
          break;
        case MYSQL_TYPE_FLOAT:        // float
        case MYSQL_TYPE_DOUBLE:       // double
          result_buffers[i].buffer = xcalloc(1, sizeof(double));
          result_buffers[i].buffer_length = sizeof(double);
          break;
        case MYSQL_TYPE_TIME:         // MYSQL_TIME
        case MYSQL_TYPE_DATE:         // MYSQL_TIME
        case MYSQL_TYPE_NEWDATE:      // MYSQL_TIME
        case MYSQL_TYPE_DATETIME:     // MYSQL_TIME
        case MYSQL_TYPE_TIMESTAMP:    // MYSQL_TIME
          result_buffers[i].buffer = xcalloc(1, sizeof(MYSQL_TIME));
          result_buffers[i].buffer_length = sizeof(MYSQL_TIME);
          break;
        case MYSQL_TYPE_DECIMAL:      // char[]
        case MYSQL_TYPE_NEWDECIMAL:   // char[]
        case MYSQL_TYPE_STRING:       // char[]
        case MYSQL_TYPE_VAR_STRING:   // char[]
        case MYSQL_TYPE_VARCHAR:      // char[]
        case MYSQL_TYPE_TINY_BLOB:    // char[]
        case MYSQL_TYPE_BLOB:         // char[]
        case MYSQL_TYPE_MEDIUM_BLOB:  // char[]
        case MYSQL_TYPE_LONG_BLOB:    // char[]
        case MYSQL_TYPE_BIT:          // char[]
        case MYSQL_TYPE_SET:          // char[]
        case MYSQL_TYPE_ENUM:         // char[]
        case MYSQL_TYPE_GEOMETRY:     // char[]
          result_buffers[i].buffer = malloc(fields[i].max_length);
          result_buffers[i].buffer_length = fields[i].max_length;
          break;
        default:
          rb_raise(cMysql2Error, "unhandled mysql type: %d", fields[i].type);
      }

      result_buffers[i].is_null = &is_null[i];
      result_buffers[i].length  = &length[i];
      result_buffers[i].error   = &error[i];
      result_buffers[i].is_unsigned = ((fields[i].flags & UNSIGNED_FLAG) != 0);
    }

    if(mysql_stmt_bind_result(stmt, result_buffers)) {
      for(i = 0; i < field_count; i++) {
        if (result_buffers[i].buffer) {
          free(result_buffers[i].buffer);
        }
      }
      free(result_buffers);
      free(is_null);
      free(error);
      free(length);
      rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt));
    }

    while(!mysql_stmt_fetch(stmt)) {
      VALUE row = rb_ary_new2((long)field_count);

      for(i = 0; i < field_count; i++) {
        VALUE column = Qnil;
        MYSQL_TIME *ts;

        if (is_null[i]) {
          column = Qnil;
        } else {
          switch(result_buffers[i].buffer_type) {
            case MYSQL_TYPE_TINY:         // signed char
              if (result_buffers[i].is_unsigned) {
                column = UINT2NUM(*((unsigned char*)result_buffers[i].buffer));
              } else {
                column = INT2NUM(*((signed char*)result_buffers[i].buffer));
              }
              break;
            case MYSQL_TYPE_SHORT:        // short int
              if (result_buffers[i].is_unsigned) {
                column = UINT2NUM(*((unsigned short int*)result_buffers[i].buffer));
              } else  {
                column = INT2NUM(*((short int*)result_buffers[i].buffer));
              }
              break;
            case MYSQL_TYPE_INT24:        // int
            case MYSQL_TYPE_LONG:         // int
            case MYSQL_TYPE_YEAR:         // int
              if (result_buffers[i].is_unsigned) {
                column = UINT2NUM(*((unsigned int*)result_buffers[i].buffer));
              } else {
                column = INT2NUM(*((int*)result_buffers[i].buffer));
              }
              break;
            case MYSQL_TYPE_LONGLONG:     // long long int
              if (result_buffers[i].is_unsigned) {
                column = ULL2NUM(*((unsigned long long int*)result_buffers[i].buffer));
              } else {
                column = LL2NUM(*((long long int*)result_buffers[i].buffer));
              }
              break;
            case MYSQL_TYPE_FLOAT:        // float
              column = rb_float_new((double)(*((float*)result_buffers[i].buffer)));
              break;
            case MYSQL_TYPE_DOUBLE:       // double
              column = rb_float_new((double)(*((double*)result_buffers[i].buffer)));
              break;
            case MYSQL_TYPE_DATE:         // MYSQL_TIME
              ts = (MYSQL_TIME*)result_buffers[i].buffer;
              column = rb_funcall(cDate, rb_intern("new"), 3, INT2NUM(ts->year), INT2NUM(ts->month), INT2NUM(ts->day));
              break;
            case MYSQL_TYPE_TIME:         // MYSQL_TIME
              ts = (MYSQL_TIME*)result_buffers[i].buffer;
              column = rb_funcall(rb_cTime,
                  rb_intern("mktime"), 6,
                  UINT2NUM(Qnil),
                  UINT2NUM(Qnil),
                  UINT2NUM(Qnil),
                  UINT2NUM(ts->hour),
                  UINT2NUM(ts->minute),
                  UINT2NUM(ts->second));
              break;
            case MYSQL_TYPE_NEWDATE:      // MYSQL_TIME
            case MYSQL_TYPE_DATETIME:     // MYSQL_TIME
            case MYSQL_TYPE_TIMESTAMP:    // MYSQL_TIME
              ts = (MYSQL_TIME*)result_buffers[i].buffer;
              column = rb_funcall(rb_cTime,
                  rb_intern("mktime"), 6,
                  UINT2NUM(ts->year),
                  UINT2NUM(ts->month),
                  UINT2NUM(ts->day),
                  UINT2NUM(ts->hour),
                  UINT2NUM(ts->minute),
                  UINT2NUM(ts->second));
              break;
            case MYSQL_TYPE_DECIMAL:      // char[]
            case MYSQL_TYPE_NEWDECIMAL:   // char[]
              column = rb_funcall(cBigDecimal, rb_intern("new"), 1, rb_str_new(result_buffers[i].buffer, *(result_buffers[i].length)));
              break;
            case MYSQL_TYPE_STRING:       // char[]
            case MYSQL_TYPE_VAR_STRING:   // char[]
            case MYSQL_TYPE_VARCHAR:      // char[]
            case MYSQL_TYPE_TINY_BLOB:    // char[]
            case MYSQL_TYPE_BLOB:         // char[]
            case MYSQL_TYPE_MEDIUM_BLOB:  // char[]
            case MYSQL_TYPE_LONG_BLOB:    // char[]
            case MYSQL_TYPE_BIT:          // char[]
            case MYSQL_TYPE_SET:          // char[]
            case MYSQL_TYPE_ENUM:         // char[]
            case MYSQL_TYPE_GEOMETRY:     // char[]
              // FIXME: handle encoding
              column = rb_str_new(result_buffers[i].buffer, *(result_buffers[i].length));
              break;
            default:
              rb_raise(cMysql2Error, "unhandled buffer type: %d",
                  result_buffers[i].buffer_type);
              break;
          }
        }

        rb_ary_store(row, (long)i, column);
      }

      rb_yield(row);
    }

    free(result_buffers);
    free(is_null);
    free(error);
    free(length);
  }

  return self;
}

void init_mysql2_statement() {
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);

  rb_define_method(cMysql2Statement, "param_count", param_count, 0);
  rb_define_method(cMysql2Statement, "field_count", field_count, 0);
  rb_define_method(cMysql2Statement, "execute", execute, -1);
  rb_define_method(cMysql2Statement, "each", each, 0);
  rb_define_method(cMysql2Statement, "fields", fields, 0);
}
