#include <mysql2_ext.h>

#include <limits.h>

#include "mysql_enc_to_ruby.h"
#define MYSQL2_CHARSETNR_SIZE (sizeof(mysql2_mysql_enc_to_rb)/sizeof(mysql2_mysql_enc_to_rb[0]))

static rb_encoding *binaryEncoding;

/* on 64bit platforms we can handle dates way outside 2038-01-19T03:14:07
 *
 * (9999*31557600) + (12*2592000) + (31*86400) + (11*3600) + (59*60) + 59
 */
#define MYSQL2_MAX_TIME 315578267999ULL

/* 0000-1-1 00:00:00 UTC
 *
 * (0*31557600) + (1*2592000) + (1*86400) + (0*3600) + (0*60) + 0
 */
#define MYSQL2_MIN_TIME 2678400ULL

#define MYSQL2_MAX_BYTES_PER_CHAR 3

/* From Mysql documentations:
 *   To distinguish between binary and nonbinary data for string data types,
 *   check whether the charsetnr value is 63. If so, the character set is binary,
 *   which indicates binary rather than nonbinary data. This enables you to distinguish BINARY
 *   from CHAR, VARBINARY from VARCHAR, and the BLOB types from the TEXT types.
 */
#define MYSQL2_BINARY_CHARSET 63

#ifndef MYSQL_TYPE_VECTOR
#define MYSQL_TYPE_VECTOR 242
#endif

#ifndef MYSQL_TYPE_JSON
#define MYSQL_TYPE_JSON 245
#endif

#ifndef NEW_TYPEDDATA_WRAPPER
#define TypedData_Get_Struct(obj, type, ignore, sval) Data_Get_Struct(obj, type, sval)
#endif

#define GET_RESULT(self) \
  mysql2_result_wrapper *wrapper; \
  TypedData_Get_Struct(self, mysql2_result_wrapper, &rb_mysql_result_type, wrapper);

typedef struct {
  int symbolizeKeys;
  int asArray;
  int castBool;
  int cacheRows;
  int cast;
  int streaming;
  unsigned long rowsPerGvlYield;
  ID db_timezone;
  ID app_timezone;
  int block_given; /* boolean */
} result_each_args;

extern VALUE mMysql2, cMysql2Client, cMysql2Error;
static VALUE cMysql2Result, cDateTime, cDate;
static VALUE opt_decimal_zero, opt_float_zero, opt_time_year, opt_time_month, opt_utc_offset;
static ID intern_new, intern_utc, intern_local, intern_localtime, intern_local_offset,
  intern_civil, intern_new_offset, intern_merge, intern_BigDecimal, intern_Float,
  intern_query_options;
static VALUE sym_symbolize_keys, sym_as, sym_array, sym_database_timezone,
  sym_application_timezone, sym_local, sym_utc, sym_cast_booleans,
  sym_cache_rows, sym_cast, sym_stream, sym_name, sym_rows_per_gvl_yield,
  sym_no_good_index_used, sym_no_index_used, sym_query_was_slow;

/* Mark any VALUEs that are only referenced in C, so the GC won't get them. */
static void rb_mysql_result_mark(void * wrapper) {
  mysql2_result_wrapper * w = wrapper;
  if (w) {
    rb_gc_mark_movable(w->fields);
    rb_gc_mark_movable(w->fieldTypes);
    rb_gc_mark_movable(w->rows);
    rb_gc_mark_movable(w->encoding);
    rb_gc_mark_movable(w->client);
    rb_gc_mark_movable(w->statement);
    rb_gc_mark_movable(w->server_flags);
  }
}

/* this may be called manually or during GC.
 *
 * from_dfree_callback must be true when called from rb_mysql_result_free
 * (the GC dfree callback, which may run during a GC sweep) and false from
 * every other caller (ordinary Ruby-level code, which has the GVL and is
 * not inside a GC sweep).
 *
 * The distinction matters because both mysql_stmt_free_result() and
 * mysql_free_result() are documented to potentially read and discard any
 * rows not yet fetched off the wire -- mysql_stmt_free_result() for an open
 * server-side cursor, mysql_free_result() for a mysql_use_result() stream
 * (its flush_use_result) -- i.e. blocking network I/O, not just freeing
 * local memory. That's fine from ordinary Ruby code (same category as any
 * other query), but unsafe from a dfree callback: it may run mid-GC-sweep,
 * possibly while this same connection is mid protocol exchange for a
 * completely different command (see mysql2_pending_stmt_close for the
 * sibling hazard already fixed for statement handles). This can only
 * happen for an abandoned streaming result (is_streaming &&
 * !streamingComplete): a fully-buffered result (mysql_store_result /
 * mysql_stmt_store_result) is already local, so freeing it never touches
 * the network regardless of context. When it's both streaming, unfinished,
 * and we're in a dfree callback, defer the actual free to the next safe
 * point instead -- see mysql2_enqueue_pending_result_free /
 * mysql2_reap_pending_result_frees in client.h/client.c. */
static void rb_mysql_result_free_result(mysql2_result_wrapper * wrapper, int from_dfree_callback) {
  int defer_free;

  if (!wrapper) return;

  if (wrapper->resultFreed != 1) {
    defer_free = from_dfree_callback && wrapper->is_streaming && !wrapper->streamingComplete
                 && wrapper->client_wrapper;

    if (wrapper->stmt_wrapper) {
      if (!wrapper->stmt_wrapper->closed) {
        if (defer_free) {
          mysql2_enqueue_pending_result_free(wrapper->client_wrapper, NULL, wrapper->stmt_wrapper->stmt);
        } else {
          mysql_stmt_free_result(wrapper->stmt_wrapper->stmt);
        }

        /* MySQL BUG? If the statement handle was previously used, and so
         * mysql_stmt_bind_result was called, and if that result set and bind buffers were freed,
         * MySQL still thinks the result set buffer is available and will prefetch the
         * first result in mysql_stmt_execute. This will corrupt or crash the program.
         * By setting bind_result_done back to 0, we make MySQL think that a result set
         * has never been bound to this statement handle before to prevent the prefetch.
         * This is just a plain C struct field write, safe to do eagerly even when the
         * actual free above was deferred. */
        wrapper->stmt_wrapper->stmt->bind_result_done = 0;
      }

      if (wrapper->statement != Qnil) {
        decr_mysql2_stmt(wrapper->stmt_wrapper);
      }

      if (wrapper->result_buffers) {
        unsigned int i;
        for (i = 0; i < wrapper->numberOfFields; i++) {
          if (wrapper->result_buffers[i].buffer) {
            xfree(wrapper->result_buffers[i].buffer);
          }
        }
        xfree(wrapper->result_buffers);
        xfree(wrapper->is_null);
        xfree(wrapper->error);
        xfree(wrapper->length);
      }
      /* Clue that the next statement execute will need to allocate a new result buffer. */
      wrapper->result_buffers = NULL;
      wrapper->result_buffers_bound = 0;
    }

    /* For prepared statements, wrapper->result is the result metadata
     * (from mysql_stmt_result_metadata), which mysql_free_result() never
     * blocks on regardless of streaming state -- only the plain-query
     * mysql_use_result() case above actually needs deferring here, but the
     * same defer_free check covers both, since a prepared-statement Result
     * always has a non-NULL stmt_wrapper (handled above) and its metadata
     * free is cheap either way. */
    if (defer_free) {
      mysql2_enqueue_pending_result_free(wrapper->client_wrapper, wrapper->result, NULL);
    } else {
      mysql_free_result(wrapper->result);
    }
    wrapper->resultFreed = 1;
  }
}

/* this is called during GC */
static void rb_mysql_result_free(void *ptr) {
  mysql2_result_wrapper *wrapper = ptr;

  /* Deliberately does NOT reset client_wrapper->state to IDLE here for an
   * abandoned stream: the actual drain (what would make the connection
   * genuinely idle again) may have just been deferred by the call below,
   * not performed. It goes back to IDLE once mysql2_reap_pending_result_frees
   * really runs the deferred free, at the next safe point.
   *
   * active_streaming_result is different: it must be cleared right here
   * regardless, even though state stays STREAMING. This object is about to
   * be reclaimed, and rb_mysql_client_mark/compact touch that field
   * unconditionally -- leaving it pointing here would crash a later GC
   * pass. Only one stream can be open at a time, so if this wrapper is
   * still an unfinished stream, it's the one (if any) that
   * active_streaming_result currently references. */
  if (wrapper->is_streaming && !wrapper->streamingComplete && wrapper->client_wrapper) {
    wrapper->client_wrapper->active_streaming_result = Qnil;
  }

  rb_mysql_result_free_result(wrapper, 1);

  // If the GC gets to client first it will be nil
  if (wrapper->client != Qnil) {
    decr_mysql2_client(wrapper->client_wrapper);
  }

  xfree(wrapper);
}

static size_t rb_mysql_result_memsize(const void * wrapper) {
  const mysql2_result_wrapper * w = wrapper;
  size_t memsize = sizeof(*w);
  if (w->stmt_wrapper) {
    memsize += sizeof(*w->stmt_wrapper);
  }
  if (w->client_wrapper) {
    memsize += sizeof(*w->client_wrapper);
  }
  return memsize;
}

#ifdef HAVE_RB_GC_MARK_MOVABLE
static void rb_mysql_result_compact(void * wrapper) {
  mysql2_result_wrapper * w = wrapper;
  if (w) {
    rb_mysql2_gc_location(w->fields);
    rb_mysql2_gc_location(w->fieldTypes);
    rb_mysql2_gc_location(w->rows);
    rb_mysql2_gc_location(w->encoding);
    rb_mysql2_gc_location(w->client);
    rb_mysql2_gc_location(w->statement);
    rb_mysql2_gc_location(w->server_flags);
  }
}
#endif

static const rb_data_type_t rb_mysql_result_type = {
  "rb_mysql_result",
  {
    rb_mysql_result_mark,
    rb_mysql_result_free,
    rb_mysql_result_memsize,
#ifdef HAVE_RB_GC_MARK_MOVABLE
    rb_mysql_result_compact,
#endif
  },
  0,
  0,
#ifdef RUBY_TYPED_FREE_IMMEDIATELY
  RUBY_TYPED_FREE_IMMEDIATELY,
#endif
};

/* See result.h. Called from ordinary Ruby-level code (has the GVL, not a
 * GC sweep), so unlike rb_mysql_result_free above it's fine to pass
 * from_dfree_callback=0 to rb_mysql_result_free_result: for a streaming
 * cursor that was abandoned mid-iteration but is still live (not yet
 * collected by GC), this performs the real, blocking
 * mysql_free_result()/mysql_stmt_free_result() call right now instead of
 * deferring it, so the server and client agree the previous command is
 * done before the next one goes out. */
void mysql2_result_force_free(VALUE self) {
  GET_RESULT(self);

  if (wrapper->resultFreed) return;

  rb_mysql_result_free_result(wrapper, 0);
  wrapper->streamingComplete = 1;
}

/* Default for the :rows_per_gvl_yield query option: how many buffered rows to
 * materialize between GVL yields. Empirical, not an alignment constant. 8192
 * rows is 0.6-1.0ms of materialization on the shapes benchmarked, which keeps a
 * thread waiting on the GVL from being blocked for a perceptible time while
 * leaving the per-row handoff cost removed. The interval is a row count but the
 * bound that matters is time, and time per row grows with row width, so a
 * result whose rows are far wider than those shapes may want a lower value. */
#define MYSQL2_ROWS_PER_GVL_YIELD_DEFAULT 8192

/*
 * Only a streaming result can hit the network from a row fetch.
 *
 * A non-streaming result has already been drained into client memory by
 * mysql_store_result (client.c) or mysql_stmt_store_result (statement.c), so
 * fetching a row from it is pointer arithmetic over that buffer and cannot
 * block. wrapper->is_streaming distinguishes the two reliably: mysql_use_result
 * is only ever called when the query options say stream: true, and the same
 * options hash is what sets wrapper->is_streaming.
 *
 * Releasing the GVL around a fetch that cannot block costs far more than the
 * fetch itself, so the callers below only do it while streaming.
 */
static void *nogvl_fetch_row(void *ptr) {
  MYSQL_RES *result = ptr;

  return mysql_fetch_row(result);
}

static void *nogvl_stmt_fetch(void *ptr) {
  MYSQL_STMT *stmt = ptr;
  uintptr_t r = mysql_stmt_fetch(stmt);

  return (void *)r;
}

static VALUE rb_mysql_result_fetch_field(VALUE self, unsigned int idx, int symbolize_keys) {
  VALUE rb_field;
  GET_RESULT(self);

  if (wrapper->fields == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }

  rb_field = rb_ary_entry(wrapper->fields, idx);
  if (rb_field == Qnil) {
    MYSQL_FIELD *field = NULL;
    rb_encoding *default_internal_enc = rb_default_internal_encoding();
    rb_encoding *conn_enc = rb_to_encoding(wrapper->encoding);

    field = mysql_fetch_field_direct(wrapper->result, idx);
    if (symbolize_keys) {
      rb_field = rb_intern3(field->name, field->name_length, rb_utf8_encoding());
      rb_field = ID2SYM(rb_field);
    } else {
#ifdef HAVE_RB_ENC_INTERNED_STR
      rb_field = rb_enc_interned_str(field->name, field->name_length, conn_enc);
      if (default_internal_enc && default_internal_enc != conn_enc) {
        rb_field = rb_str_to_interned_str(rb_str_export_to_enc(rb_field, default_internal_enc));
      }
#else
      rb_field = rb_enc_str_new(field->name, field->name_length, conn_enc);
      if (default_internal_enc && default_internal_enc != conn_enc) {
        rb_field = rb_str_export_to_enc(rb_field, default_internal_enc);
      }
      rb_obj_freeze(rb_field);
#endif
    }
    rb_ary_store(wrapper->fields, idx, rb_field);
  }

  return rb_field;
}

static int rb_mariadb_json_type(const MYSQL_FIELD *field) {
#if defined(MARIADB_PACKAGE_VERSION)
    MARIADB_CONST_STRING field_attr;

    if (!mariadb_field_attr(&field_attr, field,
                            MARIADB_FIELD_ATTR_FORMAT_NAME)) {
      return field_attr.length == 4 && !memcmp(field_attr.str, "json", 4);
    }
#endif
    return 0;
}

static VALUE rb_mysql_result_fetch_field_type(VALUE self, unsigned int idx) {
  VALUE rb_field_type;
  GET_RESULT(self);

  if (wrapper->fieldTypes == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fieldTypes = rb_ary_new2(wrapper->numberOfFields);
  }

  rb_field_type = rb_ary_entry(wrapper->fieldTypes, idx);
  if (rb_field_type == Qnil) {
    MYSQL_FIELD *field = NULL;
    rb_encoding *default_internal_enc = rb_default_internal_encoding();
    rb_encoding *conn_enc = rb_to_encoding(wrapper->encoding);
    int precision;

    field = mysql_fetch_field_direct(wrapper->result, idx);

    switch(field->type) {
      case MYSQL_TYPE_NULL:         // NULL
        rb_field_type = rb_str_new_cstr("null");
        break;
      case MYSQL_TYPE_TINY:         // signed char
        rb_field_type = rb_sprintf("tinyint(%ld)", field->length);
        break;
      case MYSQL_TYPE_SHORT:        // short int
        rb_field_type = rb_sprintf("smallint(%ld)", field->length);
        break;
      case MYSQL_TYPE_YEAR:         // short int
        rb_field_type = rb_sprintf("year(%ld)", field->length);
        break;
      case MYSQL_TYPE_INT24:        // int
        rb_field_type = rb_sprintf("mediumint(%ld)", field->length);
        break;
      case MYSQL_TYPE_LONG:         // int
        rb_field_type = rb_sprintf("int(%ld)", field->length);
        break;
      case MYSQL_TYPE_LONGLONG:     // long long int
        rb_field_type = rb_sprintf("bigint(%ld)", field->length);
        break;
      case MYSQL_TYPE_FLOAT:        // float
        rb_field_type = rb_sprintf("float(%ld,%d)", field->length, field->decimals);
        break;
      case MYSQL_TYPE_DOUBLE:       // double
        rb_field_type = rb_sprintf("double(%ld,%d)", field->length, field->decimals);
        break;
      case MYSQL_TYPE_TIME:         // MYSQL_TIME
        rb_field_type = rb_str_new_cstr("time");
        break;
      case MYSQL_TYPE_DATE:         // MYSQL_TIME
      case MYSQL_TYPE_NEWDATE:      // MYSQL_TIME
        rb_field_type = rb_str_new_cstr("date");
        break;
      case MYSQL_TYPE_DATETIME:     // MYSQL_TIME
        rb_field_type = rb_str_new_cstr("datetime");
        break;
      case MYSQL_TYPE_TIMESTAMP:    // MYSQL_TIME
        rb_field_type = rb_str_new_cstr("timestamp");
        break;
      case MYSQL_TYPE_DECIMAL:      // char[]
      case MYSQL_TYPE_NEWDECIMAL:   // char[]
        /*
          Handle precision similar to this line from mysql's code:
          https://github.com/mysql/mysql-server/blob/ea7d2e2d16ac03afdd9cb72a972a95981107bf51/sql/field.cc#L2246
        */
        // DECIMAL's max precision is 65 digits, so this narrowing is safe for any field the server actually sent.
        precision = (int)(field->length - (field->decimals > 0 ? 2 : 1));
        rb_field_type = rb_sprintf("decimal(%d,%d)", precision, field->decimals);
        break;
      case MYSQL_TYPE_STRING:       // char[]
        if (rb_mariadb_json_type(field)) {
          rb_field_type = rb_str_new_cstr("json");
        } else if (field->flags & ENUM_FLAG) {
          rb_field_type = rb_str_new_cstr("enum");
        } else if (field->flags & SET_FLAG) {
          rb_field_type = rb_str_new_cstr("set");
        } else {
          if (field->charsetnr == MYSQL2_BINARY_CHARSET) {
            rb_field_type = rb_sprintf("binary(%ld)", field->length);
          } else {
            rb_field_type = rb_sprintf("char(%ld)", field->length / MYSQL2_MAX_BYTES_PER_CHAR);
          }
        }
        break;
      case MYSQL_TYPE_VAR_STRING:   // char[]
        if (field->charsetnr == MYSQL2_BINARY_CHARSET) {
          rb_field_type = rb_sprintf("varbinary(%ld)", field->length);
        } else if (rb_mariadb_json_type(field)) {
          rb_field_type = rb_str_new_cstr("json");
        } else {
          rb_field_type = rb_sprintf("varchar(%ld)", field->length / MYSQL2_MAX_BYTES_PER_CHAR);
        }
        break;
      case MYSQL_TYPE_VARCHAR:      // char[]
        if (rb_mariadb_json_type(field)) {
          rb_field_type = rb_str_new_cstr("json");
          break;
        }
        rb_field_type = rb_sprintf("varchar(%ld)", field->length / MYSQL2_MAX_BYTES_PER_CHAR);
        break;
      case MYSQL_TYPE_TINY_BLOB:    // char[]
        rb_field_type = rb_str_new_cstr("tinyblob");
        break;
      case MYSQL_TYPE_BLOB:         // char[]
        if (rb_mariadb_json_type(field)) {
          rb_field_type = rb_str_new_cstr("json");
          break;
        }
        if (field->charsetnr == MYSQL2_BINARY_CHARSET) {
          switch(field->length) {
            case 255:
              rb_field_type = rb_str_new_cstr("tinyblob");
              break;
            case 65535:
              rb_field_type = rb_str_new_cstr("blob");
              break;
            case 16777215:
              rb_field_type = rb_str_new_cstr("mediumblob");
              break;
            case 4294967295:
              rb_field_type = rb_str_new_cstr("longblob");
            default:
              break;
          }
        } else {
          if (field->length == (255 * MYSQL2_MAX_BYTES_PER_CHAR)) {
            rb_field_type = rb_str_new_cstr("tinytext");
          } else if (field->length == (65535 * MYSQL2_MAX_BYTES_PER_CHAR)) {
            rb_field_type = rb_str_new_cstr("text");
          } else if (field->length == (16777215 * MYSQL2_MAX_BYTES_PER_CHAR)) {
            rb_field_type = rb_str_new_cstr("mediumtext");
          } else if (field->length == 4294967295) {
            rb_field_type = rb_str_new_cstr("longtext");
          } else {
            rb_field_type = rb_sprintf("text(%ld)", field->length);
          }
        }
        break;
      case MYSQL_TYPE_MEDIUM_BLOB:  // char[]
        rb_field_type = rb_str_new_cstr("mediumblob");
        break;
      case MYSQL_TYPE_LONG_BLOB:    // char[]
        rb_field_type = rb_str_new_cstr("longblob");
        break;
      case MYSQL_TYPE_BIT:          // char[]
        rb_field_type = rb_sprintf("bit(%ld)", field->length);
        break;
      case MYSQL_TYPE_SET:          // char[]
        rb_field_type = rb_str_new_cstr("set");
        break;
      case MYSQL_TYPE_ENUM:         // char[]
        rb_field_type = rb_str_new_cstr("enum");
        break;
      case MYSQL_TYPE_GEOMETRY:     // char[]
        rb_field_type = rb_str_new_cstr("geometry");
        break;
      case MYSQL_TYPE_JSON:         // json
        rb_field_type = rb_str_new_cstr("json");
        break;
      case MYSQL_TYPE_VECTOR:       // vector
        rb_field_type = rb_str_new_cstr("vector");
        break;
      default:
        rb_field_type = rb_str_new_cstr("unknown");
        break;
    }

    rb_enc_associate(rb_field_type, conn_enc);
    if (default_internal_enc) {
      rb_field_type = rb_str_export_to_enc(rb_field_type, default_internal_enc);
    }

    rb_ary_store(wrapper->fieldTypes, idx, rb_field_type);
  }

  return rb_field_type;
}

static VALUE mysql2_set_field_string_encoding(VALUE val, MYSQL_FIELD field, rb_encoding *default_internal_enc, rb_encoding *conn_enc) {
  /* if binary flag is set, respect its wishes */
  if (field.flags & BINARY_FLAG && field.charsetnr == MYSQL2_BINARY_CHARSET) {
    rb_enc_associate(val, binaryEncoding);
  } else if (!field.charsetnr) {
    /* MySQL 4.x may not provide an encoding, binary will get the bytes through */
    rb_enc_associate(val, binaryEncoding);
  } else {
    /* lookup the encoding configured on this field */
    const char *enc_name;
    int enc_index;

    enc_name = (field.charsetnr-1 < MYSQL2_CHARSETNR_SIZE) ? mysql2_mysql_enc_to_rb[field.charsetnr-1] : NULL;

    if (enc_name != NULL) {
      /* use the field encoding we were able to match */
      enc_index = rb_enc_find_index(enc_name);
      rb_enc_set_index(val, enc_index);
    } else {
      /* otherwise fall-back to the connection's encoding */
      rb_enc_associate(val, conn_enc);
    }

    if (default_internal_enc) {
      val = rb_str_export_to_enc(val, default_internal_enc);
    }
  }
  return val;
}

#ifdef HAVE_RB_TIME_TIMESPEC_NEW
#include <limits.h>
#include <time.h>

/* days_from_civil: proleptic Gregorian civil date -> days since 1970-01-01.
 * Howard Hinnant's public-domain algorithm (http://howardhinnant.github.io/date_algorithms.html). */
static inline int64_t mysql2_days_from_civil(int64_t y, unsigned int m, unsigned int d) {
  int64_t era;
  unsigned int yoe, doy, doe;
  y -= m <= 2;
  era = (y >= 0 ? y : y - 399) / 400;
  yoe = (unsigned int)(y - era * 400);
  doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (int64_t)doe - 719468;
}

/* Time construction for :utc results, equivalent to
 * Time.utc(year, month, day, hour, min, sec, usec) but without the varargs
 * dispatch and per-argument boxing of a 7-argument rb_funcall.
 *
 * INT_MAX - 1 is rb_time_timespec_new's documented sentinel for "ts is in UTC"
 * (INT_MAX means local time) -- see ruby/internal/intern/time.h.
 *
 * Returns Qnil when the value cannot be built this way, so the caller falls
 * back to the funcall path: an epoch outside time_t (32-bit time_t platforms,
 * for dates beyond 1901-2038) or an out-of-range subsecond. On 64-bit time_t
 * the narrowing check folds away at compile time. */
static VALUE mysql2_utc_time(unsigned int year, unsigned int month, unsigned int day,
                             unsigned int hour, unsigned int min, unsigned int sec,
                             unsigned long usec) {
  struct timespec ts;
  const int64_t secs = mysql2_days_from_civil((int64_t)year, month, day) * 86400LL
                       + hour * 3600 + min * 60 + sec;
  const time_t narrowed = (time_t)secs;

  if ((int64_t)narrowed != secs) return Qnil;
  if (usec >= 1000000UL) return Qnil;

  ts.tv_sec = narrowed;
  ts.tv_nsec = (long)(usec * 1000UL);
  return rb_time_timespec_new(&ts, INT_MAX - 1);
}

/* The fast path applies only to :utc, and only to wall-clock components the
 * generic Time.utc would itself accept -- it raises on out-of-range values,
 * where plain epoch arithmetic would silently wrap them. */
#define MYSQL2_UTC_FAST_PATH_OK(tz, hour, min, sec) \
  ((tz) == intern_utc && (hour) < 24 && (min) < 60 && (sec) < 60)
#endif

/* Read exactly n decimal digits. Returns 0 (leaving *out untouched) on any
 * non-digit, so callers fall back to the general parser. */
static inline int mysql2_read_uint(const char *p, int n, unsigned int *out) {
  unsigned int v = 0;
  int i;
  for (i = 0; i < n; i++) {
    unsigned char d = (unsigned char)(p[i] - '0');
    if (d > 9) return 0;
    v = v * 10 + d;
  }
  *out = v;
  return 1;
}

/* Fast path for the canonical wire format the server sends:
 * YYYY-MM-DD HH:MM:SS[.ffffff]. Fractional digits are left-aligned, so ".5"
 * is 500000 microseconds -- the same interpretation msec_char_to_uint gives
 * the sscanf output. Anything not matching exactly returns 0 and the caller
 * falls back to sscanf, preserving the original semantics for unusual input. */
static int mysql2_parse_datetime(const char *s, unsigned long len,
                                 unsigned int *year, unsigned int *month, unsigned int *day,
                                 unsigned int *hour, unsigned int *min, unsigned int *sec,
                                 unsigned int *msec) {
  unsigned int frac = 0;

  if (len < 19 || len > 26) return 0;
  if (s[4] != '-' || s[7] != '-' || s[10] != ' ' || s[13] != ':' || s[16] != ':') return 0;
  if (!mysql2_read_uint(s, 4, year) || !mysql2_read_uint(s + 5, 2, month) ||
      !mysql2_read_uint(s + 8, 2, day) || !mysql2_read_uint(s + 11, 2, hour) ||
      !mysql2_read_uint(s + 14, 2, min) || !mysql2_read_uint(s + 17, 2, sec)) return 0;

  if (len > 19) {
    unsigned long i;
    unsigned int scale = 100000;
    if (s[19] != '.' || len == 20) return 0;
    for (i = 20; i < len; i++) {
      unsigned char d = (unsigned char)(s[i] - '0');
      if (d > 9) return 0;
      frac += d * scale;
      scale /= 10;
    }
  }
  *msec = frac;
  return 1;
}

/* Fast path for the canonical DATE wire format YYYY-MM-DD. */
static int mysql2_parse_date(const char *s, unsigned long len,
                             unsigned int *year, unsigned int *month, unsigned int *day) {
  if (len != 10 || s[4] != '-' || s[7] != '-') return 0;
  return mysql2_read_uint(s, 4, year) && mysql2_read_uint(s + 5, 2, month) &&
         mysql2_read_uint(s + 8, 2, day);
}

/* Interpret microseconds digits left-aligned in fixed-width field.
 * e.g. 10.123 seconds means 10 seconds and 123000 microseconds,
 * because the microseconds are to the right of the decimal point.
 */
static unsigned int msec_char_to_uint(char *msec_char, size_t len)
{
  size_t i;
  for (i = 0; i < (len - 1); i++) {
    if (msec_char[i] == '\0') {
      msec_char[i] = '0';
    }
  }
  return (unsigned int)strtoul(msec_char, NULL, 10);
}

/* Fast path for casting integer columns, in the spirit of trilogy's
 * ll_from_buf/ull_from_buf. Every value an integer column can hold fits in
 * long long / unsigned long long, so accumulate the magnitude directly
 * instead of paying for rb_cstr2inum's base handling and Bignum machinery.
 *
 * Anything unexpected -- a non-digit, an empty string, or a magnitude that
 * would overflow unsigned long long -- falls back to rb_cstr2inum, preserving
 * the original semantics rather than trusting the wire format.
 *
 * The negative boundary needs care: the magnitude of LLONG_MIN is
 * LLONG_MAX + 1, so casting it to long long before negating is undefined
 * behavior. Return LL2NUM(LLONG_MIN) for exactly that magnitude and never
 * negate it as a signed value. */
static VALUE mysql2_cast_integer(const char *str, unsigned long len) {
  unsigned long long mag = 0;
  unsigned long i = 0;
  int negative = 0;

  if (len == 0) return rb_cstr2inum(str, 10);

  if (str[0] == '-') {
    negative = 1;
    i = 1;
  }

  if (i == len) return rb_cstr2inum(str, 10);

  for (; i < len; i++) {
    unsigned char digit = (unsigned char)(str[i] - '0');
    if (digit > 9) return rb_cstr2inum(str, 10);
    if (mag > (ULLONG_MAX - digit) / 10) return rb_cstr2inum(str, 10);
    mag = mag * 10 + digit;
  }

  if (negative) {
    if (mag <= (unsigned long long)LLONG_MAX) {
      return LL2NUM(-(long long)mag);
    } else if (mag == (unsigned long long)LLONG_MAX + 1) {
      return LL2NUM(LLONG_MIN);
    } else {
      return rb_cstr2inum(str, 10);
    }
  } else {
    return ULL2NUM(mag);
  }
}

static void rb_mysql_result_alloc_result_buffers(VALUE self, MYSQL_FIELD *fields) {
  unsigned int i;
  GET_RESULT(self);

  if (wrapper->result_buffers != NULL) return;

  wrapper->result_buffers = xcalloc(wrapper->numberOfFields, sizeof(MYSQL_BIND));
  wrapper->is_null = xcalloc(wrapper->numberOfFields, sizeof(my_bool));
  wrapper->error = xcalloc(wrapper->numberOfFields, sizeof(my_bool));
  wrapper->length = xcalloc(wrapper->numberOfFields, sizeof(unsigned long));

  for (i = 0; i < wrapper->numberOfFields; i++) {
    wrapper->result_buffers[i].buffer_type = fields[i].type;

    //      mysql type    |            C type
    switch(fields[i].type) {
      case MYSQL_TYPE_NULL:         // NULL
        break;
      case MYSQL_TYPE_TINY:         // signed char
        wrapper->result_buffers[i].buffer = xcalloc(1, sizeof(signed char));
        wrapper->result_buffers[i].buffer_length = sizeof(signed char);
        break;
      case MYSQL_TYPE_SHORT:        // short int
      case MYSQL_TYPE_YEAR:         // short int
        wrapper->result_buffers[i].buffer = xcalloc(1, sizeof(short int));
        wrapper->result_buffers[i].buffer_length = sizeof(short int);
        break;
      case MYSQL_TYPE_INT24:        // int
      case MYSQL_TYPE_LONG:         // int
        wrapper->result_buffers[i].buffer = xcalloc(1, sizeof(int));
        wrapper->result_buffers[i].buffer_length = sizeof(int);
        break;
      case MYSQL_TYPE_LONGLONG:     // long long int
        wrapper->result_buffers[i].buffer = xcalloc(1, sizeof(long long int));
        wrapper->result_buffers[i].buffer_length = sizeof(long long int);
        break;
      case MYSQL_TYPE_FLOAT:        // float
      case MYSQL_TYPE_DOUBLE:       // double
        wrapper->result_buffers[i].buffer = xcalloc(1, sizeof(double));
        wrapper->result_buffers[i].buffer_length = sizeof(double);
        break;
      case MYSQL_TYPE_TIME:         // MYSQL_TIME
      case MYSQL_TYPE_DATE:         // MYSQL_TIME
      case MYSQL_TYPE_NEWDATE:      // MYSQL_TIME
      case MYSQL_TYPE_DATETIME:     // MYSQL_TIME
      case MYSQL_TYPE_TIMESTAMP:    // MYSQL_TIME
        wrapper->result_buffers[i].buffer = xcalloc(1, sizeof(MYSQL_TIME));
        wrapper->result_buffers[i].buffer_length = sizeof(MYSQL_TIME);
        break;
      case MYSQL_TYPE_DECIMAL:      // char[]
      case MYSQL_TYPE_NEWDECIMAL:   // char[]
      case MYSQL_TYPE_STRING:       // char[]
      case MYSQL_TYPE_VAR_STRING:   // char[]
      case MYSQL_TYPE_VARCHAR:      // char[]
      case MYSQL_TYPE_TINY_BLOB:    // char[]
      case MYSQL_TYPE_BLOB:         // char[]
      case MYSQL_TYPE_MEDIUM_BLOB:  // char[]
      case MYSQL_TYPE_LONG_BLOB:    // char[]
      case MYSQL_TYPE_BIT:          // char[]
      case MYSQL_TYPE_SET:          // char[]
      case MYSQL_TYPE_ENUM:         // char[]
      case MYSQL_TYPE_GEOMETRY:     // char[]
      default:
        wrapper->result_buffers[i].buffer = xmalloc(fields[i].max_length);
        wrapper->result_buffers[i].buffer_length = fields[i].max_length;
        break;
    }

    wrapper->result_buffers[i].is_null = &wrapper->is_null[i];
    wrapper->result_buffers[i].length  = &wrapper->length[i];
    wrapper->result_buffers[i].error   = &wrapper->error[i];
    wrapper->result_buffers[i].is_unsigned = ((fields[i].flags & UNSIGNED_FLAG) != 0);
  }
}

static VALUE rb_mysql_result_fetch_row_stmt(VALUE self, MYSQL_FIELD * fields, const result_each_args *args)
{
  VALUE rowVal;
  unsigned int i = 0;

  rb_encoding *default_internal_enc;
  rb_encoding *conn_enc;
  GET_RESULT(self);

  /* The result can be freed from inside the iteration block; end the
   * iteration instead of touching freed statement buffers. Checked before
   * anything else so no code below has to reason about freed state. */
  if (wrapper->resultFreed) {
    return Qnil;
  }

  default_internal_enc = rb_default_internal_encoding();
  conn_enc = rb_to_encoding(wrapper->encoding);

  if (wrapper->fields == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }
  if (args->asArray) {
    rowVal = rb_ary_new2(wrapper->numberOfFields);
  } else {
#ifdef HAVE_RB_HASH_NEW_CAPA
    rowVal = rb_hash_new_capa(wrapper->numberOfFields);
#else
    rowVal = rb_hash_new();
#endif
  }

  if (wrapper->result_buffers == NULL) {
    rb_mysql_result_alloc_result_buffers(self, fields);
  }

  /* Bind once per result set rather than once per row. The buffers are
   * allocated exactly once (rb_mysql_result_alloc_result_buffers returns early
   * when they exist) and are never resized -- a buffer too short for a value
   * raises on MYSQL_DATA_TRUNCATED rather than reallocating -- and they are
   * only released by rb_mysql_result_free_result, which nulls the pointer and
   * clears this flag. So the addresses registered here stay valid for every
   * subsequent mysql_stmt_fetch on this result. Re-binding per row copied the
   * whole MYSQL_BIND array into the statement each time for no gain.
   *
   * Binding is tracked separately from allocation so that a failed bind is
   * still retried on a later fetch, exactly as it was when the bind ran on
   * every row. */
  if (!wrapper->result_buffers_bound) {
    if (mysql_stmt_bind_result(wrapper->stmt_wrapper->stmt, wrapper->result_buffers)) {
      rb_raise_mysql2_stmt_error(wrapper->stmt_wrapper);
    }
    wrapper->result_buffers_bound = 1;
  }

  {
    uintptr_t fetch_result;
    /* See the note above nogvl_fetch_row. A streaming result reads from the
     * socket here, so the GVL is released around that call; a buffered one is
     * already in client-library memory, so releasing costs more than the fetch.
     * The release is kept as tight as possible around the client-library call
     * because the GVL is required again immediately to build Ruby objects. */
    if (wrapper->is_streaming) {
      fetch_result = (uintptr_t)rb_thread_call_without_gvl(nogvl_stmt_fetch, wrapper->stmt_wrapper->stmt, RUBY_UBF_IO, 0);
    } else {
      fetch_result = (uintptr_t)nogvl_stmt_fetch(wrapper->stmt_wrapper->stmt);
    }
    switch(fetch_result) {
      case 0:
        /* success */
        break;

      case 1:
        /* error */
        rb_raise_mysql2_stmt_error(wrapper->stmt_wrapper);

      case MYSQL_NO_DATA:
        /* no more row */
        return Qnil;

      case MYSQL_DATA_TRUNCATED:
        rb_raise(cMysql2Error, "IMPLBUG: caught MYSQL_DATA_TRUNCATED. should not come here as buffer_length is set to fields[i].max_length.");
    }
  }

  for (i = 0; i < wrapper->numberOfFields; i++) {
    VALUE field = rb_mysql_result_fetch_field(self, i, args->symbolizeKeys);
    VALUE val = Qnil;
    MYSQL_TIME *ts;

    if (wrapper->is_null[i]) {
      val = Qnil;
    } else {
      const MYSQL_BIND* const result_buffer = &wrapper->result_buffers[i];

      switch(result_buffer->buffer_type) {
        case MYSQL_TYPE_TINY:         // signed char
          if (args->castBool && fields[i].length == 1) {
            val = (*((unsigned char*)result_buffer->buffer) != 0) ? Qtrue : Qfalse;
            break;
          }
          if (result_buffer->is_unsigned) {
            val = UINT2NUM(*((unsigned char*)result_buffer->buffer));
          } else {
            val = INT2NUM(*((signed char*)result_buffer->buffer));
          }
          break;
        case MYSQL_TYPE_BIT:        /* BIT field (MySQL 5.0.3 and up) */
          if (args->castBool && fields[i].length == 1) {
            val = (*((unsigned char*)result_buffer->buffer) != 0) ? Qtrue : Qfalse;
          }else{
            val = rb_str_new(result_buffer->buffer, *(result_buffer->length));
          }
          break;
        case MYSQL_TYPE_SHORT:        // short int
        case MYSQL_TYPE_YEAR:         // short int
          if (result_buffer->is_unsigned) {
            val = UINT2NUM(*((unsigned short int*)result_buffer->buffer));
          } else  {
            val = INT2NUM(*((short int*)result_buffer->buffer));
          }
          break;
        case MYSQL_TYPE_INT24:        // int
        case MYSQL_TYPE_LONG:         // int
          if (result_buffer->is_unsigned) {
            val = UINT2NUM(*((unsigned int*)result_buffer->buffer));
          } else {
            val = INT2NUM(*((int*)result_buffer->buffer));
          }
          break;
        case MYSQL_TYPE_LONGLONG:     // long long int
          if (result_buffer->is_unsigned) {
            val = ULL2NUM(*((unsigned long long int*)result_buffer->buffer));
          } else {
            val = LL2NUM(*((long long int*)result_buffer->buffer));
          }
          break;
        case MYSQL_TYPE_FLOAT:        // float
          val = rb_float_new((double)(*((float*)result_buffer->buffer)));
          break;
        case MYSQL_TYPE_DOUBLE:       // double
          val = rb_float_new((double)(*((double*)result_buffer->buffer)));
          break;
        case MYSQL_TYPE_DATE:         // MYSQL_TIME
        case MYSQL_TYPE_NEWDATE:      // MYSQL_TIME
          ts = (MYSQL_TIME*)result_buffer->buffer;
          /* Mirror the text-protocol semantics for zero and partial-zero
           * dates: all-zero is nil, partial-zero raises Mysql2::Error. */
          if (ts->year + ts->month + ts->day == 0) {
            val = Qnil;
          } else if (ts->month < 1 || ts->day < 1) {
            rb_raise(cMysql2Error, "Invalid date in field '%.*s': %04u-%02u-%02u",
                     (int)fields[i].name_length, fields[i].name, ts->year, ts->month, ts->day);
          } else {
            val = rb_funcall(cDate, intern_new, 3, INT2NUM(ts->year), INT2NUM(ts->month), INT2NUM(ts->day));
          }
          break;
        case MYSQL_TYPE_TIME:         // MYSQL_TIME
          ts = (MYSQL_TIME*)result_buffer->buffer;
          val = rb_funcall(rb_cTime, args->db_timezone, 7, opt_time_year, opt_time_month, opt_time_month, UINT2NUM(ts->hour), UINT2NUM(ts->minute), UINT2NUM(ts->second), ULONG2NUM(ts->second_part));
          if (!NIL_P(args->app_timezone)) {
            if (args->app_timezone == intern_local) {
              val = rb_funcall(val, intern_localtime, 0);
            } else { // utc
              val = rb_funcall(val, intern_utc, 0);
            }
          }
          break;
        case MYSQL_TYPE_DATETIME:     // MYSQL_TIME
        case MYSQL_TYPE_TIMESTAMP: {  // MYSQL_TIME
          uint64_t seconds;

          ts = (MYSQL_TIME*)result_buffer->buffer;
          seconds = (ts->year*31557600ULL) + (ts->month*2592000ULL) + (ts->day*86400ULL) + (ts->hour*3600ULL) + (ts->minute*60ULL) + ts->second;

          /* Mirror the text-protocol semantics for zero and partial-zero
           * datetimes (the text path computes the same seconds value and
           * returns nil when it is 0, raises when month or day is 0). */
          if (seconds == 0) {
            val = Qnil;
            break;
          } else if (ts->month < 1 || ts->day < 1) {
            rb_raise(cMysql2Error, "Invalid date in field '%.*s': %04u-%02u-%02u %02u:%02u:%02u",
                     (int)fields[i].name_length, fields[i].name, ts->year, ts->month, ts->day, ts->hour, ts->minute, ts->second);
          }

          if (seconds < MYSQL2_MIN_TIME || seconds > MYSQL2_MAX_TIME) { // use DateTime instead
            VALUE offset = INT2NUM(0);
            if (args->db_timezone == intern_local) {
              offset = rb_funcall(cMysql2Client, intern_local_offset, 0);
            }
            val = rb_funcall(cDateTime, intern_civil, 7, UINT2NUM(ts->year), UINT2NUM(ts->month), UINT2NUM(ts->day), UINT2NUM(ts->hour), UINT2NUM(ts->minute), UINT2NUM(ts->second), offset);
            if (!NIL_P(args->app_timezone)) {
              if (args->app_timezone == intern_local) {
                offset = rb_funcall(cMysql2Client, intern_local_offset, 0);
                val = rb_funcall(val, intern_new_offset, 1, offset);
              } else { // utc
                val = rb_funcall(val, intern_new_offset, 1, opt_utc_offset);
              }
            }
          } else {
            val = rb_funcall(rb_cTime, args->db_timezone, 7, UINT2NUM(ts->year), UINT2NUM(ts->month), UINT2NUM(ts->day), UINT2NUM(ts->hour), UINT2NUM(ts->minute), UINT2NUM(ts->second), ULONG2NUM(ts->second_part));
            if (!NIL_P(args->app_timezone)) {
              if (args->app_timezone == intern_local) {
                val = rb_funcall(val, intern_localtime, 0);
              } else { // utc
                val = rb_funcall(val, intern_utc, 0);
              }
            }
          }
          break;
        }
        case MYSQL_TYPE_DECIMAL:      // char[]
        case MYSQL_TYPE_NEWDECIMAL:   // char[]
          val = rb_funcall(rb_mKernel, intern_BigDecimal, 1, rb_str_new(result_buffer->buffer, *(result_buffer->length)));
          break;
        case MYSQL_TYPE_STRING:       // char[]
        case MYSQL_TYPE_VAR_STRING:   // char[]
        case MYSQL_TYPE_VARCHAR:      // char[]
        case MYSQL_TYPE_TINY_BLOB:    // char[]
        case MYSQL_TYPE_BLOB:         // char[]
        case MYSQL_TYPE_MEDIUM_BLOB:  // char[]
        case MYSQL_TYPE_LONG_BLOB:    // char[]
        case MYSQL_TYPE_SET:          // char[]
        case MYSQL_TYPE_ENUM:         // char[]
        case MYSQL_TYPE_GEOMETRY:     // char[]
        default:
          val = rb_str_new(result_buffer->buffer, *(result_buffer->length));
          val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc);
          break;
      }
    }

    if (args->asArray) {
      rb_ary_push(rowVal, val);
    } else {
      rb_hash_aset(rowVal, field, val);
    }
  }

  return rowVal;
}

/* Whether a MySQL DECIMAL wire value is zero: sign, digits, '.', digits,
 * no exponent, so a value is zero iff every digit is '0'. Checked with a
 * plain character scan rather than strtod(), which reads '.' according to
 * the current LC_NUMERIC and misparses this otherwise-locale-independent
 * string under any locale that uses ',' instead. */
static int decimal_str_is_zero(const char *str) {
  const char *p = str;

  if (*p == '-' || *p == '+') p++;

  for (; *p; p++) {
    if (*p != '0' && *p != '.') return 0;
  }

  return 1;
}

static VALUE rb_mysql_result_fetch_row(VALUE self, MYSQL_FIELD * fields, const result_each_args *args)
{
  VALUE rowVal;
  MYSQL_ROW row;
  unsigned int i = 0;
  unsigned long * fieldLengths;
  void * ptr;
  rb_encoding *default_internal_enc;
  rb_encoding *conn_enc;
  GET_RESULT(self);

  /* The result can be freed from inside the iteration block; end the
   * iteration instead of dereferencing the freed MYSQL_RES. Checked before
   * anything else so no code below has to reason about freed state. */
  if (wrapper->resultFreed) {
    return Qnil;
  }

  default_internal_enc = rb_default_internal_encoding();
  conn_enc = rb_to_encoding(wrapper->encoding);

  ptr = wrapper->result;
  /* See the note above nogvl_fetch_row. A streaming result reads from the
   * socket here, so the GVL is released around that call; a buffered one is
   * already in client-library memory, so releasing costs more than the fetch.
   * The release is kept as tight as possible around the client-library call
   * because the GVL is required again immediately to build Ruby objects. */
  if (wrapper->is_streaming) {
    row = (MYSQL_ROW)rb_thread_call_without_gvl(nogvl_fetch_row, ptr, RUBY_UBF_IO, 0);
  } else {
    row = mysql_fetch_row(wrapper->result);
  }
  if (row == NULL) {
    return Qnil;
  }

  if (wrapper->fields == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }
  if (args->asArray) {
    rowVal = rb_ary_new2(wrapper->numberOfFields);
  } else {
    /* Pre-size to the column count so a row with more than the default
     * number of entries does not have to rehash while being built. */
#ifdef HAVE_RB_HASH_NEW_CAPA
    rowVal = rb_hash_new_capa(wrapper->numberOfFields);
#else
    rowVal = rb_hash_new();
#endif
  }
  fieldLengths = mysql_fetch_lengths(wrapper->result);

  for (i = 0; i < wrapper->numberOfFields; i++) {
    VALUE field = rb_mysql_result_fetch_field(self, i, args->symbolizeKeys);
    if (row[i]) {
      VALUE val = Qnil;
      enum enum_field_types type = fields[i].type;

      if (!args->cast) {
        if (type == MYSQL_TYPE_NULL) {
          val = Qnil;
        } else {
          val = rb_str_new(row[i], fieldLengths[i]);
          val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc);
        }
      } else {
        switch(type) {
        case MYSQL_TYPE_NULL:       /* NULL-type field */
          val = Qnil;
          break;
        case MYSQL_TYPE_BIT:        /* BIT field (MySQL 5.0.3 and up) */
          if (args->castBool && fields[i].length == 1) {
            val = *row[i] == 1 ? Qtrue : Qfalse;
          }else{
            val = rb_str_new(row[i], fieldLengths[i]);
          }
          break;
        case MYSQL_TYPE_TINY:       /* TINYINT field */
          if (args->castBool && fields[i].length == 1) {
            val = *row[i] != '0' ? Qtrue : Qfalse;
            break;
          }
        case MYSQL_TYPE_SHORT:      /* SMALLINT field */
        case MYSQL_TYPE_LONG:       /* INTEGER field */
        case MYSQL_TYPE_INT24:      /* MEDIUMINT field */
        case MYSQL_TYPE_LONGLONG:   /* BIGINT field */
        case MYSQL_TYPE_YEAR:       /* YEAR field */
          val = mysql2_cast_integer(row[i], fieldLengths[i]);
          break;
        case MYSQL_TYPE_DECIMAL:    /* DECIMAL or NUMERIC field */
        case MYSQL_TYPE_NEWDECIMAL: /* Precision math DECIMAL or NUMERIC field (MySQL 5.0.3 and up) */
          if (fields[i].decimals == 0) {
            val = rb_cstr2inum(row[i], 10);
          } else if (decimal_str_is_zero(row[i])) {
            val = rb_funcall(rb_mKernel, intern_BigDecimal, 1, opt_decimal_zero);
          }else{
            val = rb_funcall(rb_mKernel, intern_BigDecimal, 1, rb_str_new(row[i], fieldLengths[i]));
          }
          break;
        case MYSQL_TYPE_FLOAT:      /* FLOAT field */
        case MYSQL_TYPE_DOUBLE: {     /* DOUBLE or REAL field */
          /* Kernel#Float() parses this locale-independently; strtod()
           * would read '.' according to the current LC_NUMERIC. */
          VALUE column_as_float = rb_funcall(rb_mKernel, intern_Float, 1, rb_str_new(row[i], fieldLengths[i]));
          if (RFLOAT_VALUE(column_as_float) == 0.000000){
            val = opt_float_zero;
          }else{
            val = column_as_float;
          }
          break;
        }
        case MYSQL_TYPE_TIME: {     /* TIME field */
          int tokens;
          unsigned int hour=0, min=0, sec=0, msec=0;
          char msec_char[7] = {'0','0','0','0','0','0','\0'};

          tokens = sscanf(row[i], "%2u:%2u:%2u.%6s", &hour, &min, &sec, msec_char);
          if (tokens < 3) {
            val = Qnil;
            break;
          }
          msec = msec_char_to_uint(msec_char, sizeof(msec_char));
          val = rb_funcall(rb_cTime, args->db_timezone, 7, opt_time_year, opt_time_month, opt_time_month, UINT2NUM(hour), UINT2NUM(min), UINT2NUM(sec), UINT2NUM(msec));
          if (!NIL_P(args->app_timezone)) {
            if (args->app_timezone == intern_local) {
              val = rb_funcall(val, intern_localtime, 0);
            } else { /* utc */
              val = rb_funcall(val, intern_utc, 0);
            }
          }
          break;
        }
        case MYSQL_TYPE_TIMESTAMP:  /* TIMESTAMP field */
        case MYSQL_TYPE_DATETIME: { /* DATETIME field */
          int tokens;
          int parsed_msec = 0;
          unsigned int year=0, month=0, day=0, hour=0, min=0, sec=0, msec=0;
          char msec_char[7] = {'0','0','0','0','0','0','\0'};
          uint64_t seconds;

          if (mysql2_parse_datetime(row[i], fieldLengths[i], &year, &month, &day, &hour, &min, &sec, &msec)) {
            parsed_msec = 1;
          } else {
            tokens = sscanf(row[i], "%4u-%2u-%2u %2u:%2u:%2u.%6s", &year, &month, &day, &hour, &min, &sec, msec_char);
            if (tokens < 6) { /* msec might be empty */
              val = Qnil;
              break;
            }
          }
          seconds = (year*31557600ULL) + (month*2592000ULL) + (day*86400ULL) + (hour*3600ULL) + (min*60ULL) + sec;

          if (seconds == 0) {
            val = Qnil;
          } else {
            if (month < 1 || day < 1) {
              rb_raise(cMysql2Error, "Invalid date in field '%.*s': %s", fields[i].name_length, fields[i].name, row[i]);
              val = Qnil;
            } else {
              if (seconds < MYSQL2_MIN_TIME || seconds > MYSQL2_MAX_TIME) { /* use DateTime for larger date range, does not support microseconds */
                VALUE offset = INT2NUM(0);
                if (args->db_timezone == intern_local) {
                  offset = rb_funcall(cMysql2Client, intern_local_offset, 0);
                }
                val = rb_funcall(cDateTime, intern_civil, 7, UINT2NUM(year), UINT2NUM(month), UINT2NUM(day), UINT2NUM(hour), UINT2NUM(min), UINT2NUM(sec), offset);
                if (!NIL_P(args->app_timezone)) {
                  if (args->app_timezone == intern_local) {
                    offset = rb_funcall(cMysql2Client, intern_local_offset, 0);
                    val = rb_funcall(val, intern_new_offset, 1, offset);
                  } else { /* utc */
                    val = rb_funcall(val, intern_new_offset, 1, opt_utc_offset);
                  }
                }
              } else {
                if (!parsed_msec) {
                  msec = msec_char_to_uint(msec_char, sizeof(msec_char));
                }
#ifdef HAVE_RB_TIME_TIMESPEC_NEW
                /* month/day lower bounds were validated above; the upper bounds
                 * keep a corrupt value from producing a silently-wrong epoch
                 * instead of the ArgumentError Time.utc would raise. */
                if (MYSQL2_UTC_FAST_PATH_OK(args->db_timezone, hour, min, sec) && month <= 12 && day <= 31) {
                  val = mysql2_utc_time(year, month, day, hour, min, sec, msec);
                }
                if (!NIL_P(val)) {
                  /* Already UTC, so app_timezone :utc needs no conversion. */
                  if (args->app_timezone == intern_local) {
                    val = rb_funcall(val, intern_localtime, 0);
                  }
                } else
#endif
                {
                  val = rb_funcall(rb_cTime, args->db_timezone, 7, UINT2NUM(year), UINT2NUM(month), UINT2NUM(day), UINT2NUM(hour), UINT2NUM(min), UINT2NUM(sec), UINT2NUM(msec));
                  if (!NIL_P(args->app_timezone)) {
                    if (args->app_timezone == intern_local) {
                      val = rb_funcall(val, intern_localtime, 0);
                    } else { /* utc */
                      val = rb_funcall(val, intern_utc, 0);
                    }
                  }
                }
              }
            }
          }
          break;
        }
        case MYSQL_TYPE_DATE:       /* DATE field */
        case MYSQL_TYPE_NEWDATE: {  /* Newer const used > 5.0 */
          int tokens;
          unsigned int year=0, month=0, day=0;
          if (!mysql2_parse_date(row[i], fieldLengths[i], &year, &month, &day)) {
            tokens = sscanf(row[i], "%4u-%2u-%2u", &year, &month, &day);
            if (tokens < 3) {
              val = Qnil;
              break;
            }
          }
          if (year+month+day == 0) {
            val = Qnil;
          } else {
            if (month < 1 || day < 1) {
              rb_raise(cMysql2Error, "Invalid date in field '%.*s': %s", fields[i].name_length, fields[i].name, row[i]);
              val = Qnil;
            } else {
              val = rb_funcall(cDate, intern_new, 3, UINT2NUM(year), UINT2NUM(month), UINT2NUM(day));
            }
          }
          break;
        }
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB:
        case MYSQL_TYPE_VAR_STRING:
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_STRING:     /* CHAR or BINARY field */
        case MYSQL_TYPE_SET:        /* SET field */
        case MYSQL_TYPE_ENUM:       /* ENUM field */
        case MYSQL_TYPE_GEOMETRY:   /* Spatial fielda */
        default:
          val = rb_str_new(row[i], fieldLengths[i]);
          val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc);
          break;
        }
      }
      if (args->asArray) {
        rb_ary_push(rowVal, val);
      } else {
        rb_hash_aset(rowVal, field, val);
      }
    } else {
      if (args->asArray) {
        rb_ary_push(rowVal, Qnil);
      } else {
        rb_hash_aset(rowVal, field, Qnil);
      }
    }
  }
  return rowVal;
}

static VALUE rb_mysql_result_fetch_fields(VALUE self) {
  unsigned int i = 0;
  short int symbolizeKeys = 0;
  VALUE defaults;
  VALUE fields;

  GET_RESULT(self);

  defaults = rb_ivar_get(self, intern_query_options);
  Check_Type(defaults, T_HASH);
  if (rb_hash_aref(defaults, sym_symbolize_keys) == Qtrue) {
    symbolizeKeys = 1;
  }

  if (wrapper->fields == Qnil) {
    if (wrapper->resultFreed) {
      rb_raise(cMysql2Error, "Result set has already been freed");
    }
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }

  /* See the identical guard in rb_mysql_result_fetch_field_types: keep a
   * stack-local reference alive across the fill loop so conservative stack
   * scanning finds this array too, independent of GC generation timing. */
  fields = wrapper->fields;

  if ((my_ulonglong)RARRAY_LEN(fields) != wrapper->numberOfFields) {
    for (i=0; i<wrapper->numberOfFields; i++) {
      rb_mysql_result_fetch_field(self, i, symbolizeKeys);
    }
  }

  RB_GC_GUARD(fields);
  return wrapper->fields;
}

static VALUE rb_mysql_result_fetch_field_types(VALUE self) {
  unsigned int i = 0;
  VALUE field_types;

  GET_RESULT(self);

  if (wrapper->fieldTypes == Qnil) {
    if (wrapper->resultFreed) {
      rb_raise(cMysql2Error, "Result set has already been freed");
    }
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fieldTypes = rb_ary_new2(wrapper->numberOfFields);
  }

  /* wrapper->fieldTypes lives on the C struct, not the Ruby stack: between
   * this assignment and the loop below finishing, it's reachable only
   * through wrapper, and each iteration allocates a String (a GC
   * safepoint). Keep a stack-local reference alive across the whole loop
   * so conservative stack scanning always finds it too, independent of
   * when the next mark pass would otherwise notice it via wrapper -- under
   * GC.stress a mark pass can land in that gap. See #1456. */
  field_types = wrapper->fieldTypes;

  if ((my_ulonglong)RARRAY_LEN(field_types) != wrapper->numberOfFields) {
    for (i=0; i<wrapper->numberOfFields; i++) {
      rb_mysql_result_fetch_field_type(self, i);
    }
  }

  RB_GC_GUARD(field_types);
  return wrapper->fieldTypes;
}

/* Cache the fields and fieldTypes metadata, then free the C result set.
 * Caching must happen while the result set is still valid: it keeps #fields
 * and #field_types accessible after the free. Field names not already cached
 * by row fetching (e.g. for 0-row results) are cached according to the query
 * options (such as symbolize_keys); fieldTypes is never populated by row
 * fetching.
 * See: https://github.com/brianmario/mysql2/issues/1426
 *
 * Must not be called from the GC free path (rb_mysql_result_free), which
 * cannot call back into Ruby. */
static void rb_mysql_result_cache_metadata_and_free(VALUE self) {
  GET_RESULT(self);
  rb_mysql_result_fetch_fields(self);
  rb_mysql_result_fetch_field_types(self);
  rb_mysql_result_free_result(wrapper, 0);
}

static VALUE rb_mysql_result_free_(VALUE self) {
  rb_mysql_result_cache_metadata_and_free(self);
  return Qnil;
}

static VALUE rb_mysql_result_each_(VALUE self,
                                   VALUE(*fetch_row_func)(VALUE, MYSQL_FIELD *fields, const result_each_args *args),
                                   const result_each_args *args)
{
  unsigned long i;
  const char *errstr;
  MYSQL_FIELD *fields = NULL;

  GET_RESULT(self);

  if (wrapper->is_streaming) {
    /* When streaming, we will only yield rows, not return them. */
    if (wrapper->rows == Qnil) {
      wrapper->rows = rb_ary_new();
    }

    if (!wrapper->streamingComplete) {
      VALUE row;

      fields = mysql_fetch_fields(wrapper->result);

      do {
        row = fetch_row_func(self, fields, args);
        if (row != Qnil) {
          wrapper->numberOfRows++;
          if (args->block_given) {
            rb_yield(row);
          }
        }
      } while(row != Qnil);

      rb_mysql_result_cache_metadata_and_free(self);
      wrapper->streamingComplete = 1;

      // The cursor is exhausted: the connection is free to run another
      // command. This runs from ordinary Ruby-level code (#each), so it's
      // safe to reap here rather than waiting for the next command.
      if (wrapper->client_wrapper) {
        wrapper->client_wrapper->state = MYSQL2_CLIENT_IDLE;
        wrapper->client_wrapper->active_streaming_result = Qnil;
        mysql2_reap_pending_result_frees(wrapper->client_wrapper);
        mysql2_reap_pending_stmt_closes(wrapper->client_wrapper);
      }

      // Check for errors, the connection might have gone out from under us
      // mysql_error returns an empty string if there is no error
      errstr = mysql_error(wrapper->client_wrapper->client);
      if (errstr[0]) {
        rb_raise(cMysql2Error, "%s", errstr);
      }
    } else {
      rb_raise(cMysql2Error, "You have already fetched all the rows for this query and streaming is true. (to reiterate you must requery).");
    }
  } else {
    if (args->cacheRows && wrapper->resultFreed) {
      /* we've already read the entire dataset from the C result into our */
      /* internal array. Lets hand that over to the user since it's ready to go */
      for (i = 0; i < wrapper->numberOfRows; i++) {
        rb_yield(rb_ary_entry(wrapper->rows, i));
      }
    } else {
      unsigned long rowsProcessed = 0;
      unsigned long rowsSinceYield = 0;
      rowsProcessed = RARRAY_LEN(wrapper->rows);
      fields = mysql_fetch_fields(wrapper->result);

      for (i = 0; i < wrapper->numberOfRows; i++) {
        VALUE row;
        if (args->cacheRows && i < rowsProcessed) {
          row = rb_ary_entry(wrapper->rows, i);
        } else {
          row = fetch_row_func(self, fields, args);

          /* fetch_row_func is either rb_mysql_result_fetch_row or
           * rb_mysql_result_fetch_row_stmt, which only need to hit the network
           * when streaming. Buffered rows are already in memory owned by the
           * MySQL/MariaDB client library. Those functions hold the GVL while in
           * buffered mode as rows are quickly materialized into Ruby-space.
           * Therefore call rb_thread_schedule every N rows to ensure that a very
           * large result set does not starve out other threads. Only rows
           * actually fetched are counted, so re-iterating a cached result does
           * not add scheduling points. */
          if (args->rowsPerGvlYield && ++rowsSinceYield >= args->rowsPerGvlYield) {
            rowsSinceYield = 0;
            rb_thread_schedule();
          }
          if (args->cacheRows) {
            rb_ary_store(wrapper->rows, i, row);
          }
          wrapper->lastRowProcessed++;
        }

        if (row == Qnil) {
          /* we don't need the mysql C dataset around anymore, peace it */
          if (args->cacheRows) {
            rb_mysql_result_cache_metadata_and_free(self);
          }
          return Qnil;
        }

        if (args->block_given) {
          rb_yield(row);
        }
      }
      if (wrapper->lastRowProcessed == wrapper->numberOfRows && args->cacheRows) {
        /* we don't need the mysql C dataset around anymore, peace it */
        rb_mysql_result_cache_metadata_and_free(self);
      }
    }
  }

  // FIXME return Enumerator instead?
  // return rb_ary_each(wrapper->rows);
  return wrapper->rows;
}

static VALUE rb_mysql_result_each(int argc, VALUE * argv, VALUE self) {
  result_each_args args;
  VALUE defaults, opts, (*fetch_row_func)(VALUE, MYSQL_FIELD *fields, const result_each_args *args);
  ID db_timezone, app_timezone, dbTz, appTz;
  int symbolizeKeys, asArray, castBool, cacheRows, cast;
  unsigned long rowsPerGvlYield;
  VALUE rowsPerGvlYieldOpt;

  GET_RESULT(self);

  if (wrapper->stmt_wrapper && wrapper->stmt_wrapper->closed) {
    rb_raise(cMysql2Error, "Statement handle already closed");
  }

  defaults = rb_ivar_get(self, intern_query_options);
  Check_Type(defaults, T_HASH);

  // A block can be passed to this method, but since we don't call the block directly from C,
  // we don't need to capture it into a variable here with the "&" scan arg.
  if (rb_scan_args(argc, argv, "01", &opts) == 1) {
    opts = rb_funcall(defaults, intern_merge, 1, opts);
  } else {
    opts = defaults;
  }

  symbolizeKeys = RTEST(rb_hash_aref(opts, sym_symbolize_keys));
  asArray       = rb_hash_aref(opts, sym_as) == sym_array;
  castBool      = RTEST(rb_hash_aref(opts, sym_cast_booleans));
  cacheRows     = RTEST(rb_hash_aref(opts, sym_cache_rows));
  cast          = RTEST(rb_hash_aref(opts, sym_cast));

  /* :rows_per_gvl_yield -- 0 disables yielding; nil uses the default. */
  rowsPerGvlYield = MYSQL2_ROWS_PER_GVL_YIELD_DEFAULT;
  rowsPerGvlYieldOpt = rb_hash_aref(opts, sym_rows_per_gvl_yield);
  if (!NIL_P(rowsPerGvlYieldOpt)) {
    long requested = NUM2LONG(rowsPerGvlYieldOpt);
    if (requested < 0) {
      rb_raise(cMysql2Error, ":rows_per_gvl_yield must not be negative");
    }
    rowsPerGvlYield = (unsigned long)requested;
  }

  if (wrapper->is_streaming && cacheRows) {
    rb_warn(":cache_rows is ignored if :stream is true");
  }

  if (wrapper->stmt_wrapper && !cacheRows && !wrapper->is_streaming) {
    rb_warn(":cache_rows is forced for prepared statements (if not streaming)");
    cacheRows = 1;
  }

  if (wrapper->stmt_wrapper && !cast) {
    rb_warn(":cast is forced for prepared statements");
  }

  /* A freed result can only be re-iterated from the fully cached rows array
   * (or raise the streaming-specific error below when a completed stream is
   * re-iterated); anything else would dereference the freed MYSQL_RES. The
   * rows-length check matters: with cache_rows: false the rows array stays
   * empty even after a full iteration, and replaying it would yield nil
   * rows. */
  if (wrapper->resultFreed) {
    int replayable = cacheRows && wrapper->rows != Qnil &&
                     wrapper->lastRowProcessed == wrapper->numberOfRows &&
                     (my_ulonglong)RARRAY_LEN(wrapper->rows) == wrapper->numberOfRows;
    if (wrapper->is_streaming ? !wrapper->streamingComplete : !replayable) {
      rb_raise(cMysql2Error, "Result set has already been freed");
    }
  }

  dbTz = rb_hash_aref(opts, sym_database_timezone);
  if (dbTz == sym_local) {
    db_timezone = intern_local;
  } else if (dbTz == sym_utc) {
    db_timezone = intern_utc;
  } else {
    if (!NIL_P(dbTz)) {
      rb_warn(":database_timezone option must be :utc or :local - defaulting to :local");
    }
    db_timezone = intern_local;
  }

  appTz = rb_hash_aref(opts, sym_application_timezone);
  if (appTz == sym_local) {
    app_timezone = intern_local;
  } else if (appTz == sym_utc) {
    app_timezone = intern_utc;
  } else {
    app_timezone = Qnil;
  }

  if (wrapper->rows == Qnil && !wrapper->is_streaming) {
    wrapper->numberOfRows = wrapper->stmt_wrapper ? mysql_stmt_num_rows(wrapper->stmt_wrapper->stmt) : mysql_num_rows(wrapper->result);
    /* Only reserve room for every row when the rows will actually be kept.
     * With cache_rows: false nothing is ever stored in this array, so the
     * reservation is dead weight proportional to the result size. */
    wrapper->rows = cacheRows ? rb_ary_new2(wrapper->numberOfRows) : rb_ary_new();
  } else if (wrapper->rows && !cacheRows) {
    if (wrapper->resultFreed) {
      rb_raise(cMysql2Error, "Result set has already been freed");
    }
    mysql_data_seek(wrapper->result, 0);
    wrapper->lastRowProcessed = 0;
    wrapper->rows = rb_ary_new();
  }

  // Backward compat
  args.symbolizeKeys = symbolizeKeys;
  args.asArray = asArray;
  args.castBool = castBool;
  args.cacheRows = cacheRows;
  args.rowsPerGvlYield = rowsPerGvlYield;
  args.cast = cast;
  args.db_timezone = db_timezone;
  args.app_timezone = app_timezone;
  args.block_given = rb_block_given_p();

  if (wrapper->stmt_wrapper) {
    fetch_row_func = rb_mysql_result_fetch_row_stmt;
  } else {
    fetch_row_func = rb_mysql_result_fetch_row;
  }

  return rb_mysql_result_each_(self, fetch_row_func, &args);
}

/* call-seq:
 *    result.server_flags # => Hash
 *
 * Returns the server status flags for the query that produced this result:
 * +:no_good_index_used+, +:no_index_used+, and +:query_was_slow+. Flags the
 * client library doesn't define at compile time are +nil+.
 *
 * Built on first access from the connection status captured when the result
 * was created, then memoized -- so it reflects this result's own query even
 * if the connection has run others since, and remains available after #free.
 */
#define flag_to_bool(f) ((wrapper->server_status & f) ? Qtrue : Qfalse)
static VALUE rb_mysql_result_server_flags(VALUE self) {
  GET_RESULT(self);

  if (NIL_P(wrapper->server_flags)) {
    VALUE server_flags = rb_hash_new();

#ifdef HAVE_CONST_SERVER_QUERY_NO_GOOD_INDEX_USED
    rb_hash_aset(server_flags, sym_no_good_index_used, flag_to_bool(SERVER_QUERY_NO_GOOD_INDEX_USED));
#else
    rb_hash_aset(server_flags, sym_no_good_index_used, Qnil);
#endif

#ifdef HAVE_CONST_SERVER_QUERY_NO_INDEX_USED
    rb_hash_aset(server_flags, sym_no_index_used, flag_to_bool(SERVER_QUERY_NO_INDEX_USED));
#else
    rb_hash_aset(server_flags, sym_no_index_used, Qnil);
#endif

#ifdef HAVE_CONST_SERVER_QUERY_WAS_SLOW
    rb_hash_aset(server_flags, sym_query_was_slow, flag_to_bool(SERVER_QUERY_WAS_SLOW));
#else
    rb_hash_aset(server_flags, sym_query_was_slow, Qnil);
#endif

    /* Memoize in the wrapper struct, marked from rb_mysql_result_mark: a
     * plain C field write, so it works even on a frozen Result (an ivar set
     * would raise FrozenError), and later calls return this same Hash object
     * (mutations included), as the eager version did. */
    wrapper->server_flags = server_flags;
  }

  return wrapper->server_flags;
}
#undef flag_to_bool

static VALUE rb_mysql_result_count(VALUE self) {
  GET_RESULT(self);

  if (wrapper->is_streaming) {
    /* This is an unsigned long per result.h */
    return ULONG2NUM(wrapper->numberOfRows);
  }

  if (wrapper->resultFreed) {
    /* Ruby arrays have platform signed long length */
    return LONG2NUM(RARRAY_LEN(wrapper->rows));
  } else {
    /* MySQL returns an unsigned 64-bit long here */
    if (wrapper->stmt_wrapper) {
      return ULL2NUM(mysql_stmt_num_rows(wrapper->stmt_wrapper->stmt));
    } else {
      return ULL2NUM(mysql_num_rows(wrapper->result));
    }
  }
}

/* Mysql2::Result */
VALUE rb_mysql_result_to_obj(VALUE client, VALUE encoding, VALUE options, MYSQL_RES *r, VALUE statement) {
  VALUE obj;
  mysql2_result_wrapper * wrapper;

#ifdef NEW_TYPEDDATA_WRAPPER
  obj = TypedData_Make_Struct(cMysql2Result, mysql2_result_wrapper, &rb_mysql_result_type, wrapper);
#else
  obj = Data_Make_Struct(cMysql2Result, mysql2_result_wrapper, rb_mysql_result_mark, rb_mysql_result_free, wrapper);
#endif
  wrapper->numberOfFields = 0;
  wrapper->numberOfRows = 0;
  wrapper->lastRowProcessed = 0;
  wrapper->resultFreed = 0;
  wrapper->result = r;
  wrapper->fields = Qnil;
  wrapper->fieldTypes = Qnil;
  wrapper->rows = Qnil;
  wrapper->server_flags = Qnil;
  wrapper->encoding = encoding;
  wrapper->streamingComplete = 0;
  wrapper->client = client;
  wrapper->client_wrapper = DATA_PTR(client);
  wrapper->client_wrapper->refcount++;
  /* Capture the connection's server status now, while it still reflects the
   * query that produced this result, so #server_flags can be built lazily.
   * A plain uint copy: cannot raise, per the post-streaming-registration
   * lifecycle rules in client.c/statement.c. */
  wrapper->server_status = wrapper->client_wrapper->client->server_status;
  wrapper->result_buffers = NULL;
  wrapper->result_buffers_bound = 0;
  wrapper->is_null = NULL;
  wrapper->error = NULL;
  wrapper->length = NULL;

  /* Keep a handle to the Statement to ensure it doesn't get garbage collected first */
  wrapper->statement = statement;
  if (statement != Qnil) {
    wrapper->stmt_wrapper = DATA_PTR(statement);
    wrapper->stmt_wrapper->refcount++;
  } else {
    wrapper->stmt_wrapper = NULL;
  }

  rb_obj_call_init(obj, 0, NULL);
  rb_ivar_set(obj, intern_query_options, options);

  /* Options that cannot be changed in results.each(...) { |row| }
   * should be processed here. */
  wrapper->is_streaming = (rb_hash_aref(options, sym_stream) == Qtrue ? 1 : 0);

  return obj;
}

void init_mysql2_result(void) {
  cDate = rb_const_get(rb_cObject, rb_intern("Date"));
  rb_global_variable(&cDate);
  cDateTime = rb_const_get(rb_cObject, rb_intern("DateTime"));
  rb_global_variable(&cDateTime);

  cMysql2Result = rb_define_class_under(mMysql2, "Result", rb_cObject);
  rb_undef_alloc_func(cMysql2Result);
  rb_global_variable(&cMysql2Result);

  rb_define_method(cMysql2Result, "each", rb_mysql_result_each, -1);
  rb_define_method(cMysql2Result, "fields", rb_mysql_result_fetch_fields, 0);
  rb_define_method(cMysql2Result, "field_types", rb_mysql_result_fetch_field_types, 0);
  rb_define_method(cMysql2Result, "free", rb_mysql_result_free_, 0);
  rb_define_method(cMysql2Result, "count", rb_mysql_result_count, 0);
  rb_define_method(cMysql2Result, "server_flags", rb_mysql_result_server_flags, 0);
  rb_define_alias(cMysql2Result, "size", "count");

  intern_new          = rb_intern("new");
  intern_utc          = rb_intern("utc");
  intern_local        = rb_intern("local");
  intern_merge        = rb_intern("merge");
  intern_localtime    = rb_intern("localtime");
  intern_local_offset = rb_intern("local_offset");
  intern_civil        = rb_intern("civil");
  intern_new_offset   = rb_intern("new_offset");
  intern_BigDecimal   = rb_intern("BigDecimal");
  intern_Float        = rb_intern("Float");
  intern_query_options = rb_intern("@query_options");

  sym_symbolize_keys  = ID2SYM(rb_intern("symbolize_keys"));
  sym_as              = ID2SYM(rb_intern("as"));
  sym_array           = ID2SYM(rb_intern("array"));
  sym_local           = ID2SYM(rb_intern("local"));
  sym_utc             = ID2SYM(rb_intern("utc"));
  sym_cast_booleans   = ID2SYM(rb_intern("cast_booleans"));
  sym_database_timezone     = ID2SYM(rb_intern("database_timezone"));
  sym_application_timezone  = ID2SYM(rb_intern("application_timezone"));
  sym_cache_rows     = ID2SYM(rb_intern("cache_rows"));
  sym_rows_per_gvl_yield = ID2SYM(rb_intern("rows_per_gvl_yield"));
  sym_cast           = ID2SYM(rb_intern("cast"));
  sym_stream         = ID2SYM(rb_intern("stream"));
  sym_name           = ID2SYM(rb_intern("name"));
  sym_no_good_index_used = ID2SYM(rb_intern("no_good_index_used"));
  sym_no_index_used      = ID2SYM(rb_intern("no_index_used"));
  sym_query_was_slow     = ID2SYM(rb_intern("query_was_slow"));

  opt_decimal_zero = rb_str_new2("0.0");
  rb_global_variable(&opt_decimal_zero); /*never GC */
  opt_float_zero = rb_float_new((double)0);
  rb_global_variable(&opt_float_zero);
  opt_time_year = INT2NUM(2000);
  opt_time_month = INT2NUM(1);
  opt_utc_offset = INT2NUM(0);

  binaryEncoding = rb_enc_find("binary");
}
