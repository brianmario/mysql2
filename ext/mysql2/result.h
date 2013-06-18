#ifndef MYSQL2_RESULT_H
#define MYSQL2_RESULT_H

void init_mysql2_result();
VALUE rb_mysql_result_to_obj(VALUE client, VALUE encoding, VALUE options, MYSQL_RES *r);

typedef struct {
  VALUE fields;
  VALUE rows;
  VALUE client;
  VALUE encoding;
  unsigned int numberOfFields;
  unsigned long numberOfRows;
  unsigned long lastRowProcessed;
  char streamingComplete;
  char resultFreed;
  MYSQL_RES *result;
  mysql_client_wrapper *client_wrapper;
} mysql2_result_wrapper;

#define GetMysql2Result(obj, sval) (sval = (mysql2_result_wrapper*)DATA_PTR(obj));

#endif
