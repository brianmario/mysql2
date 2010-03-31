#include <ruby.h>

#include <mysql/mysql.h>
#include <mysql/mysql_com.h>
#include <mysql/errmsg.h>
#include <mysql/mysqld_error.h>

// VALUE cBigDecimal;
// ID intern_new;

/* Mysql2 */
VALUE mMysql2;

/* Mysql2::Client */
#define GetMysql2Client(obj, sval) (sval = (MYSQL*)DATA_PTR(obj));
VALUE cMysql2Client;
static VALUE rb_mysql_client_new(VALUE klass);
static VALUE rb_mysql_client_init(VALUE self);
static VALUE rb_mysql_client_query(VALUE self, VALUE query);
void rb_mysql_client_free(void * client);

/* Mysql2::Result */
#define GetMysql2Result(obj, sval) (sval = (MYSQL_RES*)DATA_PTR(obj));
VALUE cMysql2Result;
static ID sym_symbolize_keys;
static VALUE rb_mysql_result_to_obj(MYSQL_RES * res);
void rb_mysql_result_free(void * result);
static VALUE rb_mysql_result_fetch_row(int argc, VALUE * argv, VALUE self);
static VALUE rb_mysql_result_fetch_rows(int argc, VALUE * argv, VALUE self);