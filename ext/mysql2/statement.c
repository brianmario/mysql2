#include <mysql2_ext.h>

VALUE cMysql2Statement;

/* call-seq: stmt.prepare(sql)
 *
 * Prepare +sql+ for execution
 */
static VALUE prepare(VALUE self, VALUE sql)
{
  MYSQL_STMT * stmt;
  Data_Get_Struct(self, MYSQL_STMT, stmt);

  if(mysql_stmt_prepare(stmt, StringValuePtr(sql), RSTRING_LEN(sql))) {
    rb_raise(cMysql2Error, "%s", mysql_stmt_error(stmt));
  }

  return self;
}

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
  unsigned int field_count;
  unsigned int i;
  VALUE block;

  Data_Get_Struct(self, MYSQL_STMT, stmt);

  block       = rb_block_proc();
  metadata    = mysql_stmt_result_metadata(stmt);
  fields      = mysql_fetch_fields(metadata);
  field_count = mysql_stmt_field_count(stmt);

  for(i = 0; i < field_count; i++) {
  }

  return self;
}

void init_mysql2_statement()
{
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);

  rb_define_method(cMysql2Statement, "prepare", prepare, 1);
  rb_define_method(cMysql2Statement, "param_count", param_count, 0);
  rb_define_method(cMysql2Statement, "field_count", field_count, 0);
  rb_define_method(cMysql2Statement, "execute", execute, 0);
  rb_define_method(cMysql2Statement, "each", each, 0);
  rb_define_method(cMysql2Statement, "fields", fields, 0);
}
