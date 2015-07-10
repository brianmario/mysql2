#ifndef MYSQL2_STATEMENT_H
#define MYSQL2_STATEMENT_H

extern VALUE cMysql2Statement;

typedef struct {
  VALUE client;
  MYSQL_STMT *stmt;
  int refcount;
} mysql_stmt_wrapper;

void init_mysql2_statement();
void decr_mysql2_stmt(mysql_stmt_wrapper *stmt_wrapper);

VALUE rb_mysql_stmt_new(VALUE rb_client, VALUE sql);
VALUE rb_raise_mysql2_stmt_error2(MYSQL_STMT *stmt
#ifdef HAVE_RUBY_ENCODING_H
  , rb_encoding* conn_enc
#endif
  );

#endif
