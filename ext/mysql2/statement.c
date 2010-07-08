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

void init_mysql2_statement()
{
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);

  rb_define_method(cMysql2Statement, "prepare", prepare, 1);
  rb_define_method(cMysql2Statement, "param_count", param_count, 0);
  rb_define_method(cMysql2Statement, "field_count", field_count, 0);
}
