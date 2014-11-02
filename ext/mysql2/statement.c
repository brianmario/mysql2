#include <mysql2_ext.h>

VALUE cMysql2Statement;
extern VALUE mMysql2, cMysql2Error;

void init_mysql2_statement()
{
  cMysql2Statement = rb_define_class_under(mMysql2, "Statement", rb_cObject);
}
