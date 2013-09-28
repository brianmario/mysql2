#ifndef MYSQL2_EXT
#define MYSQL2_EXT

/* tell rbx not to use it's caching compat layer
   by doing this we're making a promise to RBX that
   we'll never modify the pointers we get back from RSTRING_PTR */
#define RSTRING_NOT_MODIFIED
#include <ruby.h>
#include <fcntl.h>

#ifndef HAVE_UINT
#define HAVE_UINT
typedef unsigned short    ushort;
typedef unsigned int    uint;
#endif

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
#ifdef HAVE_RUBY_THREAD_H
#include <ruby/thread.h>
#endif

#if defined(__GNUC__) && (__GNUC__ >= 3)
#define RB_MYSQL_UNUSED __attribute__ ((unused))
#else
#define RB_MYSQL_UNUSED
#endif

#include <client.h>
#include <result.h>

#endif
