#include <ruby.h>

#include <mysql/mysql.h>
#include <mysql/mysql_com.h>
#include <mysql/errmsg.h>
#include <mysql/mysqld_error.h>

#ifdef HAVE_RUBY_ENCODING_H
#include <ruby/encoding.h>
int utf8Encoding;
#endif

/* MySQL */
VALUE mMySQL;

/* MySQL::Client */
#define GetMySQLClient(obj, sval) (sval = (MYSQL*)DATA_PTR(obj));
VALUE cMySQLClient;
static VALUE rb_mysql_client_new(VALUE klass);
static VALUE rb_mysql_client_init(VALUE self);
static VALUE rb_mysql_client_query(VALUE self, VALUE query);
void rb_mysql_client_free(void * client);

/* MySQL::Result */
#define GetMySQLResult(obj, sval) (sval = (MYSQL_RES*)DATA_PTR(obj));
VALUE cMySQLResult;
static VALUE rb_mysql_result_to_obj(MYSQL_RES * res);
void rb_mysql_result_free(void * result);
static VALUE rb_mysql_result_fetch_row(VALUE self);
static VALUE rb_mysql_result_fetch_rows(int argc, VALUE * argv, VALUE self);