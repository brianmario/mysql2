#ifndef MYSQL2_EXT
#define MYSQL2_EXT

void Init_mysql2(void);

/* tell rbx not to use it's caching compat layer
   by doing this we're making a promise to RBX that
   we'll never modify the pointers we get back from RSTRING_PTR */
#define RSTRING_NOT_MODIFIED
#include <ruby.h>

#ifdef HAVE_MYSQL_H
#include <mysql.h>
#include <errmsg.h>
#else
#include <mysql/mysql.h>
#include <mysql/errmsg.h>
#endif

#include <ruby/encoding.h>
// ruby/thread.h was added in 2.0.0. See:
// https://github.com/ruby/ruby/commit/c51a826
//
// Rubinius doesn't define this, but it ships an empty thread.h (the symbols we
// care about are in ruby.h); this is safe to remove when < 2.0.0 is no longer
// supported.
#ifdef HAVE_RUBY_THREAD_H
#include <ruby/thread.h>
#endif

#if defined(__GNUC__) && (__GNUC__ >= 3)
#define RB_MYSQL_NORETURN __attribute__ ((noreturn))
#define RB_MYSQL_UNUSED __attribute__ ((unused))
#else
#define RB_MYSQL_NORETURN
#define RB_MYSQL_UNUSED
#endif

#include <client.h>
#include <statement.h>
#include <result.h>
#include <infile.h>

#endif
