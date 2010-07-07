#ifndef MYSQL2_EXT
#define MYSQL2_EXT

#include <ruby.h>
#include <fcntl.h>

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
#endif

#if defined(__GNUC__) && (__GNUC__ >= 3)
#define RB_MYSQL_UNUSED __attribute__ ((unused))
#else
#define RB_MYSQL_UNUSED
#endif

#include <result.h>
#include <statement.h>

extern VALUE mMysql2;

/* Mysql2::Error */
extern VALUE cMysql2Error;

/* Mysql2::Result */
typedef struct {
    VALUE fields;
    VALUE rows;
    unsigned int numberOfFields;
    unsigned long numberOfRows;
    unsigned long lastRowProcessed;
    short int resultFreed;
    MYSQL_RES *result;
} mysql2_result_wrapper;
#define GetMysql2Result(obj, sval) (sval = (mysql2_result_wrapper*)DATA_PTR(obj));

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
	RB_MYSQL_UNUSED rb_unblock_function_t *ubf,
	RB_MYSQL_UNUSED void *data2)
{
	VALUE rv;

	TRAP_BEG;
	rv = func(data1);
	TRAP_END;

	return rv;
}
#endif /* ! HAVE_RB_THREAD_BLOCKING_REGION */

#endif
