#ifndef MYSQL2_STATEMENT_H
#define MYSQL2_STATEMENT_H

extern VALUE cMysql2Statement;

void init_mysql2_statement();

typedef struct {
  VALUE client;
  MYSQL_STMT* stmt;
} mysql_stmt_wrapper;

VALUE rb_mysql_stmt_new(VALUE rb_client, VALUE sql);

#endif
