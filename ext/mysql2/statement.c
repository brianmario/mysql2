#include <mysql2_ext.h>

VALUE cMysql2Statement;

/* call-seq: stmt.param_count # => 2
 *
 * Returns the number of parameters the prepared statement expects.
 */
static VALUE param_count(VALUE self)
{
  MYSQL_STMT * stmt;
  Data_Get_Struct(self, MYSQL_STMT, stmt);

  return ULL2NUM(mysql_stmt_param_count(stmt));
}

/* call-seq: stmt.field_count # => 2
 *
 * Returns the number of fields the prepared statement returns.
 */
static VALUE field_count(VALUE self)
{
  MYSQL_STMT * stmt;
  Data_Get_Struct(self, MYSQL_STMT, stmt);

  return UINT2NUM(mysql_stmt_field_count(stmt));
}

/* call-seq: stmt.execute
 *
 * Executes the current prepared statement, returns +stmt+.
 */
static VALUE execute(VALUE self)
{
  MYSQL_STMT * stmt;
  Data_Get_Struct(self, MYSQL_STMT, stmt);

  if(mysql_stmt_execute(stmt))
    rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt));

  return self;
}

/* call-seq: stmt.fields   -> array
 *
 * Returns a list of fields that will be returned by this statement.
 */
static VALUE fields(VALUE self)
{
  MYSQL_STMT * stmt;
  MYSQL_FIELD * fields;
  MYSQL_RES * metadata;
  unsigned int field_count;
  unsigned int i;
  VALUE field_list;
  VALUE cMysql2Field;

  Data_Get_Struct(self, MYSQL_STMT, stmt);
  metadata    = mysql_stmt_result_metadata(stmt);
  fields      = mysql_fetch_fields(metadata);
  field_count = mysql_stmt_field_count(stmt);
  field_list  = rb_ary_new2((long)field_count);

  cMysql2Field = rb_const_get(mMysql2, rb_intern("Field"));

  for(i = 0; i < field_count; i++) {
    VALUE argv[2];
    VALUE field;

    /* FIXME: encoding.  Also, can this return null? */
    argv[0] = rb_str_new2(fields[i].name);
    argv[1] = INT2NUM(fields[i].type);

    field = rb_class_new_instance(2, argv, cMysql2Field);

    rb_ary_store(field_list, (long)i, field);
  }

  return field_list;
}

static VALUE each(VALUE self)
{
  MYSQL_STMT * stmt;
  MYSQL_FIELD * fields;
  MYSQL_RES * metadata;

  MYSQL_BIND * binds;
  my_bool * is_null;
  my_bool * error;
  unsigned long * length;
  int int_data;
  MYSQL_TIME ts;

  unsigned int field_count;
  unsigned int i;
  VALUE block;

  Data_Get_Struct(self, MYSQL_STMT, stmt);

  block       = rb_block_proc();
  metadata    = mysql_stmt_result_metadata(stmt);
  fields      = mysql_fetch_fields(metadata);
  field_count = mysql_stmt_field_count(stmt);

  binds   = xcalloc(field_count, sizeof(MYSQL_BIND));
  is_null = xcalloc(field_count, sizeof(my_bool));
  error   = xcalloc(field_count, sizeof(my_bool));
  length  = xcalloc(field_count, sizeof(unsigned long));

  for(i = 0; i < field_count; i++) {
    switch(fields[i].type) {
      case MYSQL_TYPE_LONGLONG:
        binds[i].buffer_type = MYSQL_TYPE_LONG;
        binds[i].buffer      = (char *)&int_data;
        break;
      case MYSQL_TYPE_DATETIME:
        binds[i].buffer_type = MYSQL_TYPE_DATETIME;
        binds[i].buffer      = (char *)&ts;
        break;
      default:
        rb_raise(cMysql2Error, "unhandled mysql type: %d", fields[i].type);
    }

    binds[i].is_null = &is_null[i];
    binds[i].length  = &length[i];
    binds[i].error   = &error[i];
  }

  if(mysql_stmt_bind_result(stmt, binds)) {
    xfree(binds);
    xfree(is_null);
    xfree(error);
    xfree(length);
    rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt));
  }

  while(!mysql_stmt_fetch(stmt)) {
    VALUE row = rb_ary_new2((long)field_count);

    for(i = 0; i < field_count; i++) {
      VALUE column = Qnil;
      switch(binds[i].buffer_type) {
        case MYSQL_TYPE_LONG:
          column = INT2NUM(int_data);
          break;
        /* FIXME: maybe we want to return a datetime in this case? */
        case MYSQL_TYPE_DATETIME:
          column = rb_funcall(rb_cTime,
              rb_intern("mktime"), 6,
              UINT2NUM(ts.year),
              UINT2NUM(ts.month),
              UINT2NUM(ts.day),
              UINT2NUM(ts.hour),
              UINT2NUM(ts.minute),
              UINT2NUM(ts.second));
          break;
        default:
          rb_raise(cMysql2Error, "unhandled buffer type: %d",
              binds[i].buffer_type);
          break;
      }
      rb_ary_store(row, (long)i, column);
    }
    rb_yield(row);
  }

  xfree(binds);
  xfree(is_null);
  xfree(error);
  xfree(length);

  return self;
}

void init_mysql2_statement()
{
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);

  rb_define_method(cMysql2Statement, "param_count", param_count, 0);
  rb_define_method(cMysql2Statement, "field_count", field_count, 0);
  rb_define_method(cMysql2Statement, "execute", execute, 0);
  rb_define_method(cMysql2Statement, "each", each, 0);
  rb_define_method(cMysql2Statement, "fields", fields, 0);
}
