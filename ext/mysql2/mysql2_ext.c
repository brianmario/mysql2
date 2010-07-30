#include <mysql2_ext.h>

VALUE mMysql2, cMysql2Error, intern_encoding_from_charset;
ID    sym_id, sym_version, sym_async;

/* call-seq: client.create_statement # => Mysql2::Statement
 *
 * Create a new prepared statement.
 */
static VALUE create_statement(VALUE self)
{
  MYSQL * client;
  MYSQL_STMT * stmt;

  Data_Get_Struct(self, MYSQL, client);
  stmt = mysql_stmt_init(client);

  return Data_Wrap_Struct(cMysql2Statement, 0, mysql_stmt_close, stmt);
}

/* Ruby Extension initializer */
void Init_mysql2() {
  mMysql2      = rb_define_module("Mysql2");
  cMysql2Error = rb_const_get(mMysql2, rb_intern("Error"));

  sym_id       = ID2SYM(rb_intern("id"));
  sym_version  = ID2SYM(rb_intern("version"));
  sym_async    = ID2SYM(rb_intern("async"));

  intern_encoding_from_charset = rb_intern("encoding_from_charset");

  init_mysql2_client();
  init_mysql2_result();
  init_mysql2_statement();
}
