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

void init_mysql2_statement()
{
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);

  rb_define_method(cMysql2Statement, "prepare", prepare, 1);
}
