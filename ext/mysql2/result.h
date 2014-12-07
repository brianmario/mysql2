#ifndef MYSQL2_RESULT_H
#define MYSQL2_RESULT_H

void init_mysql2_result();
VALUE rb_mysql_result_to_obj(VALUE client, VALUE encoding, VALUE options, MYSQL_RES *r, MYSQL_STMT * s);

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
  MYSQL_STMT *stmt;
  mysql_client_wrapper *client_wrapper;
  /* statement result bind buffers */
  MYSQL_BIND *result_buffers;
  my_bool *is_null;
  my_bool *error;
  unsigned long *length;
} mysql2_result_wrapper;

#define GetMysql2Result(obj, sval) (sval = (mysql2_result_wrapper*)DATA_PTR(obj));

#endif
