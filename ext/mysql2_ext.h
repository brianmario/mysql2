#include <time.h>
#include <ruby.h>

#ifdef HAVE_MYSQL_H
#include <mysql.h>
#include <mysql_com.h>
#include <errmsg.h>
#include <mysqld_error.h>
#else
#include <mysql/mysql.h>
#include <mysql/mysql_com.h>
#include <mysql/errmsg.h>
#include <mysql/mysqld_error.h>
#endif

#ifdef HAVE_RUBY_ENCODING_H
#include <ruby/encoding.h>
int utf8Encoding, binaryEncoding;
#endif

static VALUE cBigDecimal, cDate, cDateTime;
ID intern_new, intern_local;

/* Mysql2::Error */
VALUE cMysql2Error;

/* Mysql2::Client */
#define GetMysql2Client(obj, sval) (sval = (MYSQL*)DATA_PTR(obj));
static ID sym_socket, sym_host, sym_port, sym_username, sym_password,
          sym_database, sym_reconnect, sym_connect_timeout, sym_id, sym_version,
          sym_sslkey, sym_sslcert, sym_sslca, sym_sslcapath, sym_sslcipher,
          sym_symbolize_keys, sym_async;
static VALUE rb_mysql_client_new(int argc, VALUE * argv, VALUE klass);
static VALUE rb_mysql_client_init(int argc, VALUE * argv, VALUE self);
static VALUE rb_mysql_client_query(int argc, VALUE * argv, VALUE self);
static VALUE rb_mysql_client_escape(VALUE self, VALUE str);
static VALUE rb_mysql_client_info(VALUE self);
static VALUE rb_mysql_client_server_info(VALUE self);
static VALUE rb_mysql_client_socket(VALUE self);
static VALUE rb_mysql_client_async_result(VALUE self);
void rb_mysql_client_free(void * client);

/* Mysql2::Result */
#define GetMysql2Result(obj, sval) (sval = (MYSQL_RES*)DATA_PTR(obj));
VALUE cMysql2Result;
static VALUE rb_mysql_result_to_obj(MYSQL_RES * res);
static VALUE rb_mysql_result_fetch_row(int argc, VALUE * argv, VALUE self);
static VALUE rb_mysql_result_each(int argc, VALUE * argv, VALUE self);
void rb_mysql_result_free(void * result);