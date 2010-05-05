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
static VALUE rb_mysql_client_last_id(VALUE self);
static VALUE rb_mysql_client_affected_rows(VALUE self);
void rb_mysql_client_free(void * client);

/* Mysql2::Result */
typedef struct {
    VALUE fields;
    VALUE rows;
    unsigned long numberOfFields;
    unsigned long numberOfRows;
    unsigned long lastRowProcessed;
    int resultFreed;
    MYSQL_RES *result;
} mysql2_result_wrapper;
#define GetMysql2Result(obj, sval) (sval = (mysql2_result_wrapper*)DATA_PTR(obj));
VALUE cMysql2Result;
static VALUE rb_mysql_result_to_obj(MYSQL_RES * res);
static VALUE rb_mysql_result_fetch_row(int argc, VALUE * argv, VALUE self);
static VALUE rb_mysql_result_each(int argc, VALUE * argv, VALUE self);
void rb_mysql_result_free(void * wrapper);
void rb_mysql_result_mark(void * wrapper);

/*
 * used to pass all arguments to mysql_real_connect while inside
 * rb_thread_blocking_region
 */
struct nogvl_connect_args {
    MYSQL *mysql;
    const char *host;
    const char *user;
    const char *passwd;
    const char *db;
    unsigned int port;
    const char *unix_socket;
    unsigned long client_flag;
};

/*
 * used to pass all arguments to mysql_send_query while inside
 * rb_thread_blocking_region
 */
struct nogvl_send_query_args {
    MYSQL *mysql;
    VALUE sql;
};

/*
 * partial emulation of the 1.9 rb_thread_blocking_region under 1.8,
 * this is enough for dealing with blocking I/O functions in the
 * presence of threads.
 */
#ifndef HAVE_RB_THREAD_BLOCKING_REGION
#  include <rubysig.h>
#  define RUBY_UBF_IO ((rb_unblock_function_t *)-1)
typedef void rb_unblock_function_t(void *);
typedef VALUE rb_blocking_function_t(void *);
static VALUE
rb_thread_blocking_region(
	rb_blocking_function_t *func, void *data1,
	rb_unblock_function_t *ubf, void *data2)
{
	VALUE rv;

	TRAP_BEG;
	rv = func(data1);
	TRAP_END;

	return rv;
}
#endif /* ! HAVE_RB_THREAD_BLOCKING_REGION */