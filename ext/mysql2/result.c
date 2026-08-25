#include <mysql2_ext.h>

#include <limits.h>
#include <string.h>

#include "mysql_enc_to_ruby.h"
#define MYSQL2_CHARSETNR_SIZE (sizeof(mysql2_mysql_enc_to_rb)/sizeof(mysql2_mysql_enc_to_rb[0]))

static rb_encoding *binaryEncoding;

/* Per-process cache of MySQL charsetnr -> Ruby encoding index, indexed by
 * charsetnr - 1 to mirror mysql2_mysql_enc_to_rb. Both sides of the mapping
 * are fixed for the life of the process -- the table is compiled in, and a
 * Ruby encoding's index never changes once assigned -- so entries are computed
 * once and never invalidated. Slot values are offset by +1 (0 is the "not yet
 * cached" sentinel) so that encoding index 0, ASCII-8BIT, remains cacheable;
 * -1 caches "this charsetnr has no table mapping", whose fallback (the
 * connection's encoding) is applied per result at use time, never cached.
 *
 * Concurrent writers can only race to store the same deterministic value in
 * an int slot, which is benign everywhere Ruby's GVL-based threading runs. */
static int mysql2_enc_index_cache[MYSQL2_CHARSETNR_SIZE];

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

/* How much per-cell casting #each performs, parsed from the :cast option:
 * false/nil is MYSQL2_CAST_NONE, :fast is MYSQL2_CAST_FAST, and any other
 * truthy value -- not just true -- is MYSQL2_CAST_ALL, so an unrecognized
 * value keeps meaning full casting (as every truthy value always has)
 * instead of silently opting into partial casting. */
typedef enum {
  MYSQL2_CAST_NONE = 0, /* cast: false -- every non-NULL value is a raw String */
  MYSQL2_CAST_ALL  = 1, /* cast: true -- full type casting */
  MYSQL2_CAST_FAST = 2  /* cast: :fast -- cast cheap types; defer expensive ones as Strings */
} mysql2_cast_mode;

typedef struct {
  int symbolizeKeys;
  int asArray;
  int castBool;
  int cacheRows;
  mysql2_cast_mode cast;
  int streaming;
  unsigned long rowsPerGvlYield;
  ID db_timezone;
  ID app_timezone;
  int block_given; /* boolean */
  /* Encoding.default_internal, captured once per #each call rather than once
   * per row. Changing it mid-iteration therefore no longer affects later rows
   * of that same call; the next #each call observes the new value. */
  rb_encoding *default_internal_enc;
  /* Array-mode cell scratch: one slot per field, ALLOCV-allocated (so the
   * VALUEs written into it are GC-visible) once per #each call and reused for
   * every row. Each row's cells are cast into it and the row is built with a
   * single rb_ary_new4 instead of one rb_ary_push per cell. NULL in hash mode
   * and when the fetch functions can never run (freed result). */
  VALUE *rowScratch;
} result_each_args;

extern VALUE mMysql2, cMysql2Client, cMysql2Error;
static VALUE cMysql2Result, cDateTime, cDate;
static VALUE opt_decimal_zero, opt_float_zero, opt_time_year, opt_time_month, opt_time_day, opt_utc_offset;
static VALUE opt_time_anchor_utc;
static ID intern_new, intern_utc, intern_local, intern_localtime, intern_local_offset,
  intern_civil, intern_new_offset, intern_merge, intern_BigDecimal,
  intern_query_options, intern_plus;
static VALUE sym_symbolize_keys, sym_as, sym_array, sym_database_timezone,
  sym_application_timezone, sym_local, sym_utc, sym_cast_booleans,
  sym_cache_rows, sym_cast, sym_fast, sym_stream, sym_name, sym_rows_per_gvl_yield,
  sym_no_good_index_used, sym_no_index_used, sym_query_was_slow,
  sym_force_encoding;

/* Mark any VALUEs that are only referenced in C, so the GC won't get them. */
static void rb_mysql_result_mark(void * wrapper) {
  mysql2_result_wrapper * w = wrapper;
  if (w) {
    rb_gc_mark_movable(w->fields);
    rb_gc_mark_movable(w->fieldTypes);
    rb_gc_mark_movable(w->tables);
    rb_gc_mark_movable(w->dbs);
    rb_gc_mark_movable(w->rows);
    rb_gc_mark_movable(w->encoding);
    rb_gc_mark_movable(w->client);
    rb_gc_mark_movable(w->statement);
    rb_gc_mark_movable(w->server_flags);
  }
}

/* Free the statement result bind buffers so the next fetch (or the next
 * statement execute) allocates and binds fresh ones. Called from
 * rb_mysql_result_free_result and when a fetch needs buffers of the other
 * bind-type election (see result_buffers_string_binds in result.h). */
static void rb_mysql_result_free_result_buffers(mysql2_result_wrapper *wrapper) {
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
  wrapper->result_buffers = NULL;
  wrapper->result_buffers_bound = 0;
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
      mysql_stmt_wrapper *stmt_wrapper = wrapper->stmt_wrapper;
      /* Whether the statement's metadata snapshot still describes the shape
       * these artifacts were built for: an intervening execute can have
       * rebuilt it (ALTER TABLE) while this Result sat unfreed after a
       * mid-iteration raise, and handing back buffers bound for the old
       * shape would make a later execute silently convert values into the
       * wrong C types. */
      int cache_compatible = !stmt_wrapper->closed &&
                             stmt_wrapper->metadata_epoch == wrapper->stmt_metadata_epoch;

      if (!stmt_wrapper->closed) {
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

      /* Hand the result buffers back to the statement for the next execute
       * to adopt, instead of freeing them, whenever the cache slot is open
       * and the shape still matches. Pointer moves only, so this is safe
       * from the GC dfree path too. Everything cache-related happens before
       * the decr below, which can free stmt_wrapper outright when this
       * Result held the last reference. The bind-type election travels with
       * the buffers (cached_result_buffers_string_binds): an adopting
       * execute under the other cast mode sees the mismatch at fetch time
       * and re-elects, exactly as a mid-result #each mode switch does. */
      if (wrapper->result_buffers &&
          cache_compatible && stmt_wrapper->cached_result_buffers == NULL) {
        stmt_wrapper->cached_result_buffers = wrapper->result_buffers;
        stmt_wrapper->cached_is_null = wrapper->is_null;
        stmt_wrapper->cached_error = wrapper->error;
        stmt_wrapper->cached_length = wrapper->length;
        stmt_wrapper->cached_result_buffers_string_binds = wrapper->result_buffers_string_binds;
        /* Clue that the next statement execute will need to allocate or
         * adopt a result buffer. */
        wrapper->result_buffers = NULL;
        wrapper->result_buffers_bound = 0;
      } else {
        rb_mysql_result_free_result_buffers(wrapper);
      }

      /* Hand back the field-name array as a private dup, so caller
       * mutations of this Result's #fields can never reach the cache. Only
       * from the ordinary free path -- rb_ary_dup allocates, which a GC
       * dfree callback must not -- and only for a non-streaming Result:
       * those are materialized and freed entirely inside Statement#execute,
       * so the array provably carries the execute-time :symbolize_keys and
       * no user code has run against it. A streaming Result's names are
       * built under its first #each's options instead, which may differ. */
      if (!from_dfree_callback && !wrapper->is_streaming && cache_compatible &&
          wrapper->fields != Qnil &&
          (my_ulonglong)RARRAY_LEN(wrapper->fields) == wrapper->numberOfFields &&
          (stmt_wrapper->cached_fields == Qnil ||
           stmt_wrapper->cached_fields_symbolized != wrapper->fields_symbolized)) {
        stmt_wrapper->cached_fields = rb_ary_dup(wrapper->fields);
        stmt_wrapper->cached_fields_symbolized = wrapper->fields_symbolized;
      }

      if (wrapper->statement != Qnil) {
        decr_mysql2_stmt(stmt_wrapper);
      }
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
    rb_mysql2_gc_location(w->tables);
    rb_mysql2_gc_location(w->dbs);
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
    rb_encoding *conn_enc = wrapper->conn_enc;
    size_t name_length;
    const char *name_end;

    /* A name that was never cached has to be read from the result, which the
     * force-free of an abandoned stream has already released. Hash-mode rows
     * cache names one cell at a time, so a raise between cells leaves the tail
     * of the set uncached and still reachable through #fields.
     *
     * Checked per name rather than over the set as a whole, so that names
     * cached before the free still answer, as callers after an ordinary free
     * expect. */
    if (wrapper->resultFreed) {
      rb_raise(cMysql2Error, "Result set has already been freed");
    }

    field = mysql_fetch_field_direct(wrapper->result, idx);

    /* The C API defines MYSQL_FIELD.name as a NUL-terminated string, so
     * nothing past the first NUL is part of the name -- but the library can
     * deliver a name_length that counts bytes beyond it. A long expression
     * name truncated under GROUP BY arrives here with name_length 257 for a
     * 255-byte name: the terminator plus one arbitrary byte (#1288). Stop
     * at the terminator, capped by name_length. */
    name_end = memchr(field->name, '\0', field->name_length);
    name_length = name_end ? (size_t)(name_end - field->name) : field->name_length;

    if (symbolize_keys) {
#ifdef HAVE_RB_CHECK_SYMBOL_CSTR
      rb_field = rb_check_symbol_cstr(field->name, name_length, rb_utf8_encoding());
      if (rb_field == Qnil) {
        rb_field = rb_str_intern(rb_enc_str_new(field->name, name_length, rb_utf8_encoding()));
      }
#else
      rb_field = rb_intern3(field->name, name_length, rb_utf8_encoding());
      rb_field = ID2SYM(rb_field);
#endif
    } else {
#ifdef HAVE_RB_ENC_INTERNED_STR
      rb_field = rb_enc_interned_str(field->name, name_length, conn_enc);
      if (default_internal_enc && default_internal_enc != conn_enc) {
        rb_field = rb_str_to_interned_str(rb_str_export_to_enc(rb_field, default_internal_enc));
      }
#else
      rb_field = rb_enc_str_new(field->name, name_length, conn_enc);
      if (default_internal_enc && default_internal_enc != conn_enc) {
        rb_field = rb_str_export_to_enc(rb_field, default_internal_enc);
      }
      rb_obj_freeze(rb_field);
#endif
    }
    rb_ary_store(wrapper->fields, idx, rb_field);
    wrapper->fields_symbolized = symbolize_keys ? 1 : 0;
  }

  return rb_field;
}

static VALUE rb_mysql_result_fetch_table(VALUE self, unsigned int idx) {
  VALUE rb_table;
  GET_RESULT(self);

  if (wrapper->tables == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->tables = rb_ary_new2(wrapper->numberOfFields);
  }

  rb_table = rb_ary_entry(wrapper->tables, idx);
  if (rb_table == Qnil) {
    MYSQL_FIELD *field = NULL;
    rb_encoding *default_internal_enc = rb_default_internal_encoding();
    rb_encoding *conn_enc = rb_to_encoding(wrapper->encoding);

    field = mysql_fetch_field_direct(wrapper->result, idx);
#ifdef HAVE_RB_ENC_INTERNED_STR
    rb_table = rb_enc_interned_str(field->table, field->table_length, conn_enc);
    if (default_internal_enc && default_internal_enc != conn_enc) {
      rb_table = rb_str_to_interned_str(rb_str_export_to_enc(rb_table, default_internal_enc));
    }
#else
    rb_table = rb_enc_str_new(field->table, field->table_length, conn_enc);
    if (default_internal_enc && default_internal_enc != conn_enc) {
      rb_table = rb_str_export_to_enc(rb_table, default_internal_enc);
    }
    rb_obj_freeze(rb_table);
#endif
    rb_ary_store(wrapper->tables, idx, rb_table);
  }

  return rb_table;
}

static VALUE rb_mysql_result_fetch_db(VALUE self, unsigned int idx) {
  VALUE rb_db;
  GET_RESULT(self);

  if (wrapper->dbs == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->dbs = rb_ary_new2(wrapper->numberOfFields);
  }

  rb_db = rb_ary_entry(wrapper->dbs, idx);
  if (rb_db == Qnil) {
    MYSQL_FIELD *field = NULL;
    rb_encoding *default_internal_enc = rb_default_internal_encoding();
    rb_encoding *conn_enc = rb_to_encoding(wrapper->encoding);

    field = mysql_fetch_field_direct(wrapper->result, idx);
#ifdef HAVE_RB_ENC_INTERNED_STR
    rb_db = rb_enc_interned_str(field->db, field->db_length, conn_enc);
    if (default_internal_enc && default_internal_enc != conn_enc) {
      rb_db = rb_str_to_interned_str(rb_str_export_to_enc(rb_db, default_internal_enc));
    }
#else
    rb_db = rb_enc_str_new(field->db, field->db_length, conn_enc);
    if (default_internal_enc && default_internal_enc != conn_enc) {
      rb_db = rb_str_export_to_enc(rb_db, default_internal_enc);
    }
    rb_obj_freeze(rb_db);
#endif
    rb_ary_store(wrapper->dbs, idx, rb_db);
  }

  return rb_db;
}

/* Materialize every field name into wrapper->fields at once, honoring the
 * given symbolize_keys. Array mode calls this once per result set, on the
 * first fetched row, before converting any of that row's values.
 *
 * The first-row, before-any-values timing is load-bearing, not just a fast
 * path: #fields on an abandoned streaming result (force-freed by the next
 * query, skipping rb_mysql_result_cache_metadata_and_free) can only return
 * names already materialized, and a per-each :symbolize_keys caches names
 * first-call-wins. Filling the whole array here preserves both.
 *
 * Fills run ascending from 0, as in the per-cell hash path, so
 * RARRAY_LEN == numberOfFields exactly when every name is cached -- the
 * same done-check rb_mysql_result_fetch_fields uses -- and a raise
 * mid-fill is healed by the next row's call.
 *
 * The caller must ensure wrapper->fields is allocated and the result is not
 * freed. */
static void rb_mysql_result_materialize_field_names(VALUE self, int symbolize_keys) {
  unsigned int i;
  VALUE fields;
  GET_RESULT(self);

  /* See the identical guard in rb_mysql_result_fetch_fields: keep a
   * stack-local reference alive across the fill loop so conservative stack
   * scanning finds the array too, independent of GC generation timing. */
  fields = wrapper->fields;

  if ((my_ulonglong)RARRAY_LEN(fields) != wrapper->numberOfFields) {
    for (i = 0; i < wrapper->numberOfFields; i++) {
      rb_mysql_result_fetch_field(self, i, symbolize_keys);
    }
  }

  RB_GC_GUARD(fields);
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
    rb_encoding *conn_enc = wrapper->conn_enc;
    int precision;

    /* See the matching check in rb_mysql_result_fetch_field. #field_types
     * hands back the internal array, so a caller can shorten it and send the
     * next lookup back here after the result is gone. */
    if (wrapper->resultFreed) {
      rb_raise(cMysql2Error, "Result set has already been freed");
    }

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

/* See result.h. Runs at the query/execute entry points, never per row. */
void mysql2_canonicalize_force_encoding(VALUE opts) {
  VALUE requested = rb_hash_aref(opts, sym_force_encoding);

  if (!NIL_P(requested)) {
    rb_hash_aset(opts, sym_force_encoding, rb_enc_from_encoding(rb_to_encoding(requested)));
  }
}

static VALUE mysql2_set_field_string_encoding(VALUE val, MYSQL_FIELD field, rb_encoding *default_internal_enc, rb_encoding *conn_enc, rb_encoding *forced_enc) {
  /* :force_encoding retags the value with the caller's chosen encoding --
   * bytes unchanged, no transcoding. Force means force: it overrides the
   * binary branch below (BLOB/BINARY columns get retagged too) and skips
   * the default_internal conversion. Returning before the charsetnr cache
   * is consulted also keeps the forced path from ever touching it. */
  if (forced_enc) {
    rb_enc_associate(val, forced_enc);
    return val;
  }

  /* if binary flag is set, respect its wishes */
  if (field.flags & BINARY_FLAG && field.charsetnr == MYSQL2_BINARY_CHARSET) {
    rb_enc_associate(val, binaryEncoding);
  } else if (!field.charsetnr) {
    /* MySQL 4.x may not provide an encoding, binary will get the bytes through */
    rb_enc_associate(val, binaryEncoding);
  } else {
    /* lookup the encoding configured on this field, consulting the
     * per-process charsetnr cache before the name-based lookup */
    int enc_index = -1;

    if (field.charsetnr >= 1 && field.charsetnr <= MYSQL2_CHARSETNR_SIZE) {
      const int cached = mysql2_enc_index_cache[field.charsetnr - 1];

      if (cached > 0) {
        enc_index = cached - 1;
      } else if (cached == 0) {
        /* not yet cached: do the name-based lookup once and store it */
        const char *enc_name = mysql2_mysql_enc_to_rb[field.charsetnr - 1];

        if (enc_name != NULL) {
          enc_index = rb_enc_find_index(enc_name);
          if (enc_index >= 0) {
            mysql2_enc_index_cache[field.charsetnr - 1] = enc_index + 1;
          }
        } else {
          mysql2_enc_index_cache[field.charsetnr - 1] = -1;
        }
      }
      /* cached < 0: known to have no table mapping; fall through to conn_enc */
    }

    if (enc_index >= 0) {
      /* use the field encoding we were able to match */
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

/* The :local fast path additionally needs localtime_r and the BSD
 * tm_gmtoff member; platforms without them (Windows CRT lacks both) keep
 * every :local DATETIME on the funcall path. */
#if defined(HAVE_RB_TIME_TIMESPEC_NEW) && defined(HAVE_LOCALTIME_R) && defined(HAVE_STRUCT_TM_TM_GMTOFF)
#define MYSQL2_LOCAL_FAST_PATH 1
#endif

#ifdef MYSQL2_LOCAL_FAST_PATH
/* Time construction for :local results -- the gem's default timezone --
 * equivalent to Time.local(year, month, day, hour, min, sec, usec) for wall
 * times away from a zone transition, without the varargs dispatch,
 * per-argument boxing, and repeated offset search of the funcall path.
 *
 * The mechanism is offset-guess-and-verify built on localtime_r alone:
 * mktime is deliberately not used (it re-derives the zone state on every
 * call and measures slower than the entire funcall path it would replace,
 * where localtime_r reads cached zone data). The wall clock becomes a
 * UTC-shaped epoch via days_from_civil; subtracting the zone offset gives a
 * candidate instant, and one localtime_r round-trip proves or refutes it.
 * On a wrong guess the probe's own tm_gmtoff supplies the correction, and
 * one more round-trip settles it.
 *
 * Correctness near transitions is handled by refusal, not resolution: a
 * result is served only when the zone offset is provably constant across
 * [t - window, t + window] (one localtime_r at each end). Inside that
 * stable band a nonexistent wall time (spring-forward gap) cannot verify
 * and an ambiguous one (fall-back fold) cannot exist, with no assumption
 * about the transition's size or direction -- half-hour and negative-DST
 * zones are covered by construction. Near a transition the caller falls
 * back to Time.local, byte-identical with the funcall path.
 *
 * Serving is also bounded to wall-clock years [1970, 2038), because
 * outside that range Ruby and the C library disagree in some zones even
 * away from transitions: below it tzdata answers in seconds-precision
 * Local Mean Time while Ruby maps through a congruent modern year (year
 * 1000 in Denver: four seconds apart), and from 2038 the two interpret a
 * zone's post-table extension rule differently (America/Nuuk 2038-04-15:
 * -01:00 to Ruby, -02:00 to libc). Both sides are internally consistent,
 * so no round-trip can arbitrate; the funcall owns both tails.
 *
 * The proven band, its offset, and the TZ environment value it was proven
 * under are memoized on the result wrapper: datetime columns cluster in
 * time, so in the common case each cell costs exactly one localtime_r,
 * and concurrently iterated results keep independent proofs instead of
 * evicting each other's. The cache is written under the GVL (this path
 * never releases it). Serving compares the live TZ string against the
 * memoized copy. It does not compare pointers, because setenv can reuse
 * the same allocation for a new value; and offset equality alone cannot
 * distinguish two zones that share an offset but disagree inside a fold.
 * A changed TZ re-routes into re-proving; staleness costs probes, never a
 * wrong answer.
 *
 * The remaining Qnil cases mirror mysql2_utc_time: an epoch outside
 * time_t, an out-of-range subsecond, plus a TZ value too long to memoize. */
#define MYSQL2_LOCAL_STABLE_WINDOW (54 * 3600) /* clears any real DST step and fold width */
/* The margin bounds how close to a proven band's edge a value may be
 * served, so a transition hiding just past a window endpoint cannot make
 * an in-band wall time ambiguous: the largest backward step in any zone's
 * [1970, 2038) history is 7 hours (Antarctica/Vostok, 1994; next largest
 * 3), and the margin covers it four times over. */
#define MYSQL2_LOCAL_SERVE_MARGIN (30 * 3600)
/* Serve window bounds on the wall-clock year. Outside them Ruby and libc
 * disagree in some zones even away from transitions, so the funcall owns
 * both tails. Measured by a dense differential (Time.local vs localtime_r,
 * all 418 zone.tab zones x every year 1970-2039 x every month, 351,120
 * cases, tzdata 2026c): every steady-state disagreement is >= 2038,
 * confined to America/Nuuk, America/Scoresbysund, Asia/Gaza, Asia/Hebron;
 * below 1970 tzdata answers in seconds-precision Local Mean Time while
 * Ruby maps through a congruent modern year. Re-measure when tzdata moves. */
#define MYSQL2_LOCAL_SERVE_YEAR_MIN 1970
#define MYSQL2_LOCAL_SERVE_YEAR_MAX 2038 /* exclusive */
static VALUE mysql2_local_time(mysql2_result_wrapper *wrapper,
                               unsigned int year, unsigned int month, unsigned int day,
                               unsigned int hour, unsigned int min, unsigned int sec,
                               unsigned long usec) {
  struct timespec ts;
  struct tm chk;
  const char *tz;
  size_t tz_len;
  const int64_t wall = mysql2_days_from_civil((int64_t)year, month, day) * 86400LL
                       + hour * 3600 + min * 60 + sec;
  int64_t guess;
  time_t t, edge;
  int attempt, in_band, tz_same;

  if (usec >= 1000000UL) return Qnil;
  if (year < MYSQL2_LOCAL_SERVE_YEAR_MIN || year >= MYSQL2_LOCAL_SERVE_YEAR_MAX) return Qnil;

  tz = getenv("TZ");
  tz_len = tz ? strlen(tz) : 0;
  if (tz != NULL && tz_len >= sizeof(wrapper->local_band.tz)) return Qnil;
  tz_same = tz != NULL ? (wrapper->local_band.tz_state == 1 && strcmp(wrapper->local_band.tz, tz) == 0)
                       : wrapper->local_band.tz_state == 0;

  guess = wall - wrapper->local_band.off;
  for (attempt = 0; attempt < 2; attempt++) {
    t = (time_t)guess;
    if ((int64_t)t != guess) return Qnil;
    if (localtime_r(&t, &chk) == NULL) return Qnil;
    if (chk.tm_year == (int)year - 1900 && chk.tm_mon == (int)month - 1 &&
        chk.tm_mday == (int)day && chk.tm_hour == (int)hour &&
        chk.tm_min == (int)min && chk.tm_sec == (int)sec)
      break;
    /* Wrong offset (cold cache, cluster moved, or TZ changed): the probe
     * itself says what the offset is near this instant. A second miss
     * means the wall time has no instant at this offset either -- the
     * spring-forward gap, or a transition closer than the probe -- so
     * decline. */
    guess = wall - chk.tm_gmtoff;
  }
  if (attempt == 2) return Qnil;

  /* POSIX rule strings permit offsets up to +/-24:59:59, and beyond one
   * day Ruby's own wall-clock mapping stops round-tripping, so no libc
   * agreement can imply Time.local parity there. Real zones stay within
   * +/-14 hours; anything past a day is Time.local's to interpret. */
  if (chk.tm_gmtoff >= 86400 || chk.tm_gmtoff <= -86400) return Qnil;

  in_band = tz_same && chk.tm_gmtoff == wrapper->local_band.off &&
            t >= wrapper->local_band.lo + MYSQL2_LOCAL_SERVE_MARGIN &&
            t <= wrapper->local_band.hi - MYSQL2_LOCAL_SERVE_MARGIN;
  if (!in_band) {
    /* Prove the offset constant across the window around t, then memoize
     * the band. Refuse anything near a transition (gap, fold, or a
     * mid-window offset step) rather than resolving it.
     *
     * The tzset is unconditional, not gated on the TZ string differing
     * from the band's: localtime_r is not required to notice a changed TZ
     * (glibc's never does -- it skips the implicit tzset that plain
     * localtime performs), and libc's zone state can have moved and moved
     * back through values this function never observed. Proving a band
     * from stale zone state would memoize another zone's offsets under
     * the live string; refreshing first makes the proof and the string
     * agree. Serving from an already-proven band needs no refresh: a
     * stale offset fails the in_band check above and lands here. */
    struct tm lo, hi;
    const int64_t lo64 = (int64_t)t - MYSQL2_LOCAL_STABLE_WINDOW;
    const int64_t hi64 = (int64_t)t + MYSQL2_LOCAL_STABLE_WINDOW;
    if ((int64_t)(time_t)lo64 != lo64 || (int64_t)(time_t)hi64 != hi64) return Qnil;
    tzset();
    if (localtime_r(&t, &chk) == NULL) return Qnil;
    if (chk.tm_year != (int)year - 1900 || chk.tm_mon != (int)month - 1 ||
        chk.tm_mday != (int)day || chk.tm_hour != (int)hour ||
        chk.tm_min != (int)min || chk.tm_sec != (int)sec ||
        chk.tm_gmtoff >= 86400 || chk.tm_gmtoff <= -86400)
      return Qnil;
    edge = (time_t)lo64;
    if (localtime_r(&edge, &lo) == NULL) return Qnil;
    edge = (time_t)hi64;
    if (localtime_r(&edge, &hi) == NULL) return Qnil;
    if (lo.tm_gmtoff != chk.tm_gmtoff || hi.tm_gmtoff != chk.tm_gmtoff) return Qnil;
    wrapper->local_band.lo = (time_t)lo64;
    wrapper->local_band.hi = (time_t)hi64;
    wrapper->local_band.off = chk.tm_gmtoff;
    if (tz != NULL) {
      memcpy(wrapper->local_band.tz, tz, tz_len + 1);
      wrapper->local_band.tz_state = 1;
    } else {
      wrapper->local_band.tz_state = 0;
    }
    /* t is the band's center, window - margin = 24h inside the serve
     * interior, so a freshly proven band always serves its own center. */
  }

  ts.tv_sec = t;
  ts.tv_nsec = (long)(usec * 1000UL);
  /* INT_MAX is rb_time_timespec_new's documented sentinel for "local time"
   * (INT_MAX - 1 means UTC) -- see the note on mysql2_utc_time above.
   *
   * The sentinel defers zone decomposition to the value's first accessor,
   * where Time.local performs it at construction. The instant is identical
   * either way; the difference is observable only when ENV['TZ'] changes
   * between materialization and first access, in which case this value
   * renders its wall clock under the newer zone. Decomposition is most of
   * Time.local's per-cell cost, so pinning it here (one accessor funcall)
   * would surrender the fast path's entire margin -- measured, not
   * estimated. */
  return rb_time_timespec_new(&ts, INT_MAX);
}

/* Same wall-clock bounds rationale as the :utc gate above. */
#define MYSQL2_LOCAL_FAST_PATH_OK(tz, hour, min, sec) \
  ((tz) == intern_local && (hour) < 24 && (min) < 60 && (sec) < 60)
#endif /* MYSQL2_LOCAL_FAST_PATH */
#endif

/* MySQL TIME is a signed duration of hour, minute, second, and
 * microseconds, ranging from -838:59:59.999999 to 838:59:59.999999, but
 * Ruby's Time constructor rejects an hour beyond 24 or a negative value.
 * We solve this by adding the signed duration to a Time anchored at
 * 2000-01-01 00:00:00. Duration is converted to an Integer in seconds
 * or a Rational in microseconds, depending on the precision of the
 * field. */
static VALUE mysql2_time_from_duration(VALUE db_timezone, int negative,
                                       unsigned int hour, unsigned int min, unsigned int sec,
                                       unsigned long usec) {
  VALUE anchor, offset;
  int64_t total_sec = (int64_t)hour * 3600 + (int64_t)min * 60 + (int64_t)sec;

  /* :utc has no environment dependence, so the cached anchor is exact.
   * :local can't be cached the same way: Time.local re-reads ENV['TZ']
   * on every call. */
  anchor = (db_timezone == intern_utc) ? opt_time_anchor_utc
         : rb_funcall(rb_cTime, intern_local, 7, opt_time_year, opt_time_month, opt_time_day,
                      INT2FIX(0), INT2FIX(0), INT2FIX(0), INT2FIX(0));

  if (usec == 0) {
    offset = LL2NUM(negative ? -total_sec : total_sec);
  } else {
    int64_t total_usec = total_sec * 1000000LL + (int64_t)usec;
    if (negative) total_usec = -total_usec;
    offset = rb_rational_new(LL2NUM(total_usec), INT2FIX(1000000));
  }
  /* returns a newly-allocated object, anchor is not mutated */
  return rb_funcall(anchor, intern_plus, 1, offset);
}

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

/* Parses an snprintf()-formatted buffer with rb_cstr_to_dbl(), raising
 * instead of silently accepting a formatted value snprintf() truncated. */
static double mysql2_snprintf_to_dbl(const char *buf, size_t bufsize, int written) {
  if (written < 0 || (size_t)written >= bufsize) {
    rb_raise(cMysql2Error, "FLOAT/DOUBLE value too wide for buffer (%d bytes)", written);
  }
  return rb_cstr_to_dbl(buf, 0);
}

/* Shared by the binary and text protocols' FLOAT/DOUBLE cases: copies a
 * pre-formatted numeric string into a bounded buffer and parses it. */
static VALUE mysql2_float_from_str(const char *str, unsigned long len, VALUE zero_val) {
  char float_buf[512]; /* larger than the worst-case DOUBLE(255,30) plus headroom */
  int float_len = snprintf(float_buf, sizeof(float_buf), "%.*s", (int)len, str);
  double d = mysql2_snprintf_to_dbl(float_buf, sizeof(float_buf), float_len);
  return (d == 0.000000) ? zero_val : rb_float_new(d);
}

/* Initial size for variable-length (char[]) result buffers. Wide enough that
 * typical short strings, decimals, enums, and sets never truncate; anything
 * wider grows to fit on first encounter and stays grown. */
#define MYSQL2_INITIAL_BUFFER_LENGTH 128

static void rb_mysql_result_alloc_result_buffers(VALUE self, MYSQL_FIELD *fields, int stringBinds) {
  unsigned int i;
  GET_RESULT(self);

  if (wrapper->result_buffers != NULL) return;

  wrapper->result_buffers = xcalloc(wrapper->numberOfFields, sizeof(MYSQL_BIND));
  wrapper->is_null = xcalloc(wrapper->numberOfFields, sizeof(my_bool));
  wrapper->error = xcalloc(wrapper->numberOfFields, sizeof(my_bool));
  wrapper->length = xcalloc(wrapper->numberOfFields, sizeof(unsigned long));
  wrapper->result_buffers_string_binds = stringBinds;

  for (i = 0; i < wrapper->numberOfFields; i++) {
    if (stringBinds) {
      /* cast: false / :fast -- bind MYSQL_TYPE_STRING so the client library
       * converts every value to its string form (the documented
       * mysql_stmt_bind_result conversion table) and no per-cell cast layer
       * is needed on fetch. Fixed-width server types need type-derived
       * sizes: for a stored result fields[i].max_length is the BINARY wire
       * length (4 bytes for an INT), not the converted string length, and
       * for a streaming result it is 0. Each constant is the widest value
       * the type can print ("-2147483648" for LONG, "-838:59:59.000000" for
       * TIME, ...), further widened to fields[i].length because the client
       * library pads ZEROFILL columns to their display width and my_fcvt
       * output for a DOUBLE(M,D) scales with M and D. FLOAT/DOUBLE get
       * enough headroom that the conversion never has to round: libmysql
       * limits my_gcvt precision to the bind's buffer_length, so an
       * undersized buffer would silently lose digits rather than report
       * truncation. Variable-length types keep max_length sizing and the
       * MYSQL_DATA_TRUNCATED grow-and-refetch backstop, exactly as under
       * server-type binds. */
      unsigned long len;
      int fixed_width = 1;

      switch(fields[i].type) {
        case MYSQL_TYPE_NULL:
          len = 0;
          break;
        case MYSQL_TYPE_TINY:
          len = 4;   // "-128"
          break;
        case MYSQL_TYPE_SHORT:
        case MYSQL_TYPE_YEAR:
          len = 6;   // "-32768"
          break;
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
          len = 11;  // "-2147483648"
          break;
        case MYSQL_TYPE_LONGLONG:
          len = 20;  // "-9223372036854775808"
          break;
        case MYSQL_TYPE_FLOAT:
        case MYSQL_TYPE_DOUBLE:
          len = 512; // my_fcvt worst case (DOUBLE(255,30) fixed notation) plus headroom
          break;
        case MYSQL_TYPE_TIME:
          len = 17;  // "-838:59:59.000000"
          break;
        case MYSQL_TYPE_DATE:
        case MYSQL_TYPE_NEWDATE:
          len = 10;  // "2010-04-04"
          break;
        case MYSQL_TYPE_DATETIME:
        case MYSQL_TYPE_TIMESTAMP:
          len = 26;  // "2010-04-04 11:44:00.123456"
          break;
        default:
          /* Variable-length: fields[i].length is the declared maximum (4GB
           * for LONGBLOB), so only the fixed-width widening below wants it. */
          len = fields[i].max_length;
          fixed_width = 0;
          break;
      }
      if (fields[i].type != MYSQL_TYPE_NULL) {
        if (fixed_width && len < fields[i].length) len = fields[i].length;
        wrapper->result_buffers[i].buffer_type = MYSQL_TYPE_STRING;
        wrapper->result_buffers[i].buffer = xmalloc(len);
      } else {
        wrapper->result_buffers[i].buffer_type = MYSQL_TYPE_NULL;
      }
      wrapper->result_buffers[i].buffer_length = len;

      wrapper->result_buffers[i].is_null = &wrapper->is_null[i];
      wrapper->result_buffers[i].length  = &wrapper->length[i];
      wrapper->result_buffers[i].error   = &wrapper->error[i];
      wrapper->result_buffers[i].is_unsigned = ((fields[i].flags & UNSIGNED_FLAG) != 0);
      continue;
    }

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
        /* Variable-length columns start small and grow on demand: a value
         * that doesn't fit comes back as MYSQL_DATA_TRUNCATED, and the
         * fetch loop grows the buffer to the reported length and re-fetches
         * the missing tail (see rb_mysql_result_fetch_row_stmt). Buffers
         * never shrink, so each one levels off at its column's widest value
         * actually read rather than the column's declared maximum. */
        wrapper->result_buffers[i].buffer = xmalloc(MYSQL2_INITIAL_BUFFER_LENGTH);
        wrapper->result_buffers[i].buffer_length = MYSQL2_INITIAL_BUFFER_LENGTH;
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
  VALUE rowVal = Qnil;
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

  /* Cached at #each entry / Result creation to avoid per-row lookups. */
  default_internal_enc = args->default_internal_enc;
  conn_enc = wrapper->conn_enc;

  if (wrapper->fields == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->fields = rb_ary_new2(wrapper->numberOfFields);
  }
  if (!args->asArray) {
#ifdef HAVE_RB_HASH_NEW_CAPA
    rowVal = rb_hash_new_capa(wrapper->numberOfFields);
#else
    rowVal = rb_hash_new();
#endif
  }

  /* Bind types are elected from the cast mode (see the string-binds arm of
   * rb_mysql_result_alloc_result_buffers), so buffers left by an earlier
   * #each with the other cast mode cannot be decoded through -- free them
   * and let the re-allocation below elect afresh. The client library
   * applies result binds at fetch time, so rows not yet fetched (this only
   * arises when an earlier iteration stopped short) convert under the new
   * types; already-yielded rows are unaffected. */
  if (wrapper->result_buffers != NULL &&
      wrapper->result_buffers_string_binds != (args->cast != MYSQL2_CAST_ALL)) {
    rb_mysql_result_free_result_buffers(wrapper);
  }

  if (wrapper->result_buffers == NULL) {
    rb_mysql_result_alloc_result_buffers(self, fields, args->cast != MYSQL2_CAST_ALL);
  }

  /* Bind once per result set rather than once per row. The buffers are
   * allocated exactly once (rb_mysql_result_alloc_result_buffers returns early
   * when they exist), and the addresses registered here stay valid for every
   * subsequent mysql_stmt_fetch until a variable-length column's buffer is
   * grown -- see the MYSQL_DATA_TRUNCATED case below. Both client libraries
   * copy the MYSQL_BIND array into the statement handle at bind time, so a
   * grow (xrealloc may move the buffer) leaves the registered copy pointing
   * at freed memory; the grow path clears this flag so the next fetch
   * re-registers the current addresses first. Re-binding per row copied the
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

      case MYSQL_DATA_TRUNCATED: {
        /* One or more variable-length columns arrived wider than their
         * current buffer (wrapper->error[j], populated by the fetch). Grow
         * each one to the length the server reported for this row
         * (wrapper->length[j], also populated by the fetch) and complete it
         * with mysql_stmt_fetch_column(), MySQL's documented recovery for
         * this case. The truncating fetch already copied the first
         * buffer_length bytes and xrealloc preserves them, so the re-fetch
         * starts at that offset and copies only the missing tail -- from the
         * client library's own row buffer, so no network I/O and no GVL
         * release. The tail fetch reports into scratch variables: the row's
         * authoritative length/error/is_null were already set by the
         * truncating fetch, and what a partial fetch writes back to them
         * differs between client libraries. */
        unsigned int j;

        /* Growing can move a buffer, leaving the binds registered in the
         * statement handle pointing at freed memory, so re-register them
         * before the next fetch. Cleared before the loop rather than after
         * it so a mid-loop allocation failure or fetch_column error cannot
         * leave a stale registration behind for a rescued fetch to write
         * through. */
        wrapper->result_buffers_bound = 0;

        for (j = 0; j < wrapper->numberOfFields; j++) {
          MYSQL_BIND tail;
          unsigned long filled, tail_length = 0;
          my_bool tail_error = 0;
          my_bool tail_is_null = 0;

          if (!wrapper->error[j]) continue;

          filled = wrapper->result_buffers[j].buffer_length;
          wrapper->result_buffers[j].buffer = xrealloc(wrapper->result_buffers[j].buffer, wrapper->length[j]);
          wrapper->result_buffers[j].buffer_length = wrapper->length[j];

          tail = wrapper->result_buffers[j];
          tail.buffer = (char *)tail.buffer + filled;
          tail.buffer_length = wrapper->length[j] - filled;
          tail.length = &tail_length;
          tail.error = &tail_error;
          tail.is_null = &tail_is_null;

          if (mysql_stmt_fetch_column(wrapper->stmt_wrapper->stmt, &tail, j, filled)) {
            rb_raise_mysql2_stmt_error(wrapper->stmt_wrapper);
          }
        }
        break;
      }
    }
  }

  /* Placed after the fetch above rather than with the wrapper->fields
   * allocation so an empty result set stays untouched, exactly as it was
   * when the (never-entered) cell loop did the materializing. */
  if (args->asArray) {
    rb_mysql_result_materialize_field_names(self, args->symbolizeKeys);
  }

  /* cast: false -- every column is string-bound (see
   * rb_mysql_result_alloc_result_buffers), so every non-NULL cell is the
   * client library's string conversion of the value: a raw String with the
   * right encoding, no type dispatch at all. This loop is the stmt twin of
   * the MYSQL2_CAST_NONE loop in rb_mysql_result_fetch_row: the same
   * length-based rb_str_new (embedded NULs intact), the same
   * mysql2_set_field_string_encoding, the same MYSQL_TYPE_NULL and NULL-cell
   * handling, and the same key-before-value evaluation order. */
  if (args->cast == MYSQL2_CAST_NONE) {
    for (i = 0; i < wrapper->numberOfFields; i++) {
      /* Hash keys only; array-mode names were batch-materialized above. */
      VALUE field = args->asArray ? Qnil : rb_mysql_result_fetch_field(self, i, args->symbolizeKeys);
      VALUE val;

      if (!wrapper->is_null[i] && fields[i].type != MYSQL_TYPE_NULL) {
        val = rb_str_new(wrapper->result_buffers[i].buffer, wrapper->length[i]);
        val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
      } else {
        val = Qnil;
      }

      if (args->asArray) {
        args->rowScratch[i] = val;
      } else {
        rb_hash_aset(rowVal, field, val);
      }
    }
    if (args->asArray) {
      rowVal = rb_ary_new4(wrapper->numberOfFields, args->rowScratch);
    }
    return rowVal;
  }

  for (i = 0; i < wrapper->numberOfFields; i++) {
    /* Hash keys only; array-mode names were batch-materialized above. */
    VALUE field = args->asArray ? Qnil : rb_mysql_result_fetch_field(self, i, args->symbolizeKeys);
    VALUE val = Qnil;
    MYSQL_TIME *ts;

    if (wrapper->is_null[i]) {
      val = Qnil;
    } else if (args->cast == MYSQL2_CAST_FAST) {
      /* cast: :fast over string-bound columns: dispatch on the server type
       * (every buffer_type is MYSQL_TYPE_STRING here) and mirror the text
       * path's :fast contract cell for cell -- cast the cheap types from
       * their string bytes with the same mechanisms (mysql2_cast_integer,
       * Kernel#Float, the :cast_booleans checks), defer everything
       * expensive (DECIMAL, temporals) as tagged Strings. */
      const MYSQL_BIND* const result_buffer = &wrapper->result_buffers[i];
      const char *str = result_buffer->buffer;
      const unsigned long len = *(result_buffer->length);

      switch(fields[i].type) {
        case MYSQL_TYPE_NULL:
          val = Qnil;
          break;
        case MYSQL_TYPE_TINY:
          if (args->castBool && fields[i].length == 1) {
            val = *str != '0' ? Qtrue : Qfalse;
            break;
          }
          /* Deliberate fallthrough into the integer cases, exactly as in
           * rb_mysql_result_fetch_row. */
        case MYSQL_TYPE_SHORT:
        case MYSQL_TYPE_LONG:
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONGLONG:
        case MYSQL_TYPE_YEAR:
          val = mysql2_cast_integer(str, len);
          break;
        case MYSQL_TYPE_BIT:
          /* String-bound BIT is a byte copy, so the boolean check reads the
           * raw byte, as the text path reads the wire byte. */
          if (args->castBool && fields[i].length == 1) {
            val = *str == 1 ? Qtrue : Qfalse;
          } else {
            val = rb_str_new(str, len);
          }
          break;
        case MYSQL_TYPE_FLOAT:
        case MYSQL_TYPE_DOUBLE:
          val = mysql2_float_from_str(str, len, opt_float_zero);
          break;
        default:
          val = rb_str_new(str, len);
          val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
          break;
      }
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
        case MYSQL_TYPE_FLOAT: {      // float
          /* The binary format for a FLOAT column is a 32-bit IEEE-754
           * single-precision float. Ruby Float is always a 64-bit double,
           * so we need to do a little work to convert the value reliably.
           * A naive up-cast from float to double will invent high-precision noise.
           *
           * FLOAT(M,D) displays up to M digits total, and stores up to D
           * digits to the right of the decimal point. decimals == 31 is
           * MySQL's NOT_FIXED_DEC sentinel for "no explicit precision" --
           * format with 6 significant digits instead, matching FLOAT's
           * own default display precision.
           *
           * Convert float to string using snprintf (actually ruby_snprintf,
           * which ruby/subst.h #defines snprintf to, and which always uses
           * '.' as the decimal separator regardless of locale), then parse
           * the string to Ruby Float with rb_cstr_to_dbl().
           *
           * Size the buffer for the worst case: 39 integer digits, 30
           * decimals, sign, point, NUL. */
          char float_buf[80];
          double float_as_double = (double)(*((float*)result_buffer->buffer));
          int float_len;
          if (fields[i].decimals == 31) {
            float_len = snprintf(float_buf, sizeof(float_buf), "%.6g", float_as_double);
          } else {
            float_len = snprintf(float_buf, sizeof(float_buf), "%.*f", fields[i].decimals, float_as_double);
          }
          val = rb_float_new(mysql2_snprintf_to_dbl(float_buf, sizeof(float_buf), float_len));
          break;
        }
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
          /* ts->neg is the sign; hour/minute/second/second_part are the unsigned magnitude. */
          val = mysql2_time_from_duration(args->db_timezone, ts->neg, ts->hour, ts->minute, ts->second, ts->second_part);
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
          val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
          break;
      }
    }

    if (args->asArray) {
      args->rowScratch[i] = val;
    } else {
      rb_hash_aset(rowVal, field, val);
    }
  }

  if (args->asArray) {
    rowVal = rb_ary_new4(wrapper->numberOfFields, args->rowScratch);
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
  VALUE rowVal = Qnil;
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

  /* Cached at #each entry / Result creation to avoid per-row lookups. */
  default_internal_enc = args->default_internal_enc;
  conn_enc = wrapper->conn_enc;

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
    /* This runs after the NULL-row check above, so it materializes on the
     * first fetched row and an empty result set stays untouched, exactly
     * as it was when the (never-entered) cell loop did the materializing. */
    rb_mysql_result_materialize_field_names(self, args->symbolizeKeys);
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

  /* cast: false wants every non-NULL value as a raw String with the right
   * encoding, so the per-cell type dispatch below is pure overhead for it.
   * This loop is the cast: false arm of the general loop with the dispatch
   * hoisted out; everything else is kept cell-for-cell identical -- the same
   * length-based rb_str_new (embedded NULs intact), the same
   * mysql2_set_field_string_encoding, the same MYSQL_TYPE_NULL and NULL-cell
   * handling, and the same key-before-value evaluation order -- so rows are
   * byte-identical with just fewer branches per cell. Runs entirely with the
   * GVL held (the only nogvl region in this function is the streaming row
   * fetch above). */
  if (args->cast == MYSQL2_CAST_NONE) {
    for (i = 0; i < wrapper->numberOfFields; i++) {
      /* Hash keys only; array-mode names were batch-materialized above. */
      VALUE field = args->asArray ? Qnil : rb_mysql_result_fetch_field(self, i, args->symbolizeKeys);
      VALUE val;

      if (row[i] && fields[i].type != MYSQL_TYPE_NULL) {
        val = rb_str_new(row[i], fieldLengths[i]);
        val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
      } else {
        val = Qnil;
      }

      if (args->asArray) {
        args->rowScratch[i] = val;
      } else {
        rb_hash_aset(rowVal, field, val);
      }
    }
    if (args->asArray) {
      rowVal = rb_ary_new4(wrapper->numberOfFields, args->rowScratch);
    }
    return rowVal;
  }

  for (i = 0; i < wrapper->numberOfFields; i++) {
    /* Hash keys only; array-mode names were batch-materialized above. */
    VALUE field = args->asArray ? Qnil : rb_mysql_result_fetch_field(self, i, args->symbolizeKeys);
    if (row[i]) {
      VALUE val = Qnil;
      enum enum_field_types type = fields[i].type;

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
          /* Deliberate fallthrough into the integer cases: cast: true and
           * cast: :fast share this dispatch, so :cast_booleans still wins
           * for TINYINT(1) under both, and any other TINYINT is an Integer. */
        case MYSQL_TYPE_SHORT:      /* SMALLINT field */
        case MYSQL_TYPE_LONG:       /* INTEGER field */
        case MYSQL_TYPE_INT24:      /* MEDIUMINT field */
        case MYSQL_TYPE_LONGLONG:   /* BIGINT field */
        case MYSQL_TYPE_YEAR:       /* YEAR field */
          val = mysql2_cast_integer(row[i], fieldLengths[i]);
          break;
        case MYSQL_TYPE_DECIMAL:    /* DECIMAL or NUMERIC field */
        case MYSQL_TYPE_NEWDECIMAL: /* Precision math DECIMAL or NUMERIC field (MySQL 5.0.3 and up) */
          /* cast: :fast defers BigDecimal construction to the caller: the
           * raw wire bytes as a String, tagged exactly like the
           * MYSQL2_CAST_NONE loop above tags them. Scale-0 DECIMALs (an
           * Integer under cast: true) stay Strings too -- the mode is a
           * per-type contract, not a per-value one. The same deferral
           * repeats in the temporal cases below. */
          if (args->cast == MYSQL2_CAST_FAST) {
            val = rb_str_new(row[i], fieldLengths[i]);
            val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
            break;
          }
          if (fields[i].decimals == 0) {
            val = rb_cstr2inum(row[i], 10);
          } else if (decimal_str_is_zero(row[i])) {
            val = rb_funcall(rb_mKernel, intern_BigDecimal, 1, opt_decimal_zero);
          }else{
            val = rb_funcall(rb_mKernel, intern_BigDecimal, 1, rb_str_new(row[i], fieldLengths[i]));
          }
          break;
        case MYSQL_TYPE_FLOAT:      /* FLOAT field */
        case MYSQL_TYPE_DOUBLE:       /* DOUBLE or REAL field */
          val = mysql2_float_from_str(row[i], fieldLengths[i], opt_float_zero);
          break;
        case MYSQL_TYPE_TIME: {     /* TIME field */
          int tokens, negative;
          const char *time_str = row[i];
          unsigned int hour=0, min=0, sec=0, msec=0;
          char msec_char[7] = {'0','0','0','0','0','0','\0'};

          if (args->cast == MYSQL2_CAST_FAST) {
            val = rb_str_new(row[i], fieldLengths[i]);
            val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
            break;
          }

          negative = (time_str[0] == '-');
          if (negative) time_str++;

          /* %3u: MySQL's TIME hour ranges up to 838, one digit wider than a
           * time-of-day's 0-23 (#719). */
          tokens = sscanf(time_str, "%3u:%2u:%2u.%6s", &hour, &min, &sec, msec_char);
          if (tokens < 3) {
            val = Qnil;
            break;
          }
          msec = msec_char_to_uint(msec_char, sizeof(msec_char));
          val = mysql2_time_from_duration(args->db_timezone, negative, hour, min, sec, msec);
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

          if (args->cast == MYSQL2_CAST_FAST) {
            val = rb_str_new(row[i], fieldLengths[i]);
            val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
            break;
          }

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
                if (month <= 12 && day <= 31) {
                  if (MYSQL2_UTC_FAST_PATH_OK(args->db_timezone, hour, min, sec)) {
                    val = mysql2_utc_time(year, month, day, hour, min, sec, msec);
                    /* Already UTC, so app_timezone :utc needs no conversion. */
                    if (!NIL_P(val) && args->app_timezone == intern_local) {
                      val = rb_funcall(val, intern_localtime, 0);
                    }
#ifdef MYSQL2_LOCAL_FAST_PATH
                  } else if (MYSQL2_LOCAL_FAST_PATH_OK(args->db_timezone, hour, min, sec)) {
                    val = mysql2_local_time(wrapper, year, month, day, hour, min, sec, msec);
                    /* Already local, so app_timezone :local needs no conversion. */
                    if (!NIL_P(val) && args->app_timezone == intern_utc) {
                      val = rb_funcall(val, intern_utc, 0);
                    }
#endif
                  }
                }
                if (NIL_P(val))
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
          if (args->cast == MYSQL2_CAST_FAST) {
            val = rb_str_new(row[i], fieldLengths[i]);
            val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
            break;
          }
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
          val = mysql2_set_field_string_encoding(val, fields[i], default_internal_enc, conn_enc, wrapper->forced_enc);
          break;
      }
      if (args->asArray) {
        args->rowScratch[i] = val;
      } else {
        rb_hash_aset(rowVal, field, val);
      }
    } else {
      if (args->asArray) {
        args->rowScratch[i] = Qnil;
      } else {
        rb_hash_aset(rowVal, field, Qnil);
      }
    }
  }
  if (args->asArray) {
    rowVal = rb_ary_new4(wrapper->numberOfFields, args->rowScratch);
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

static VALUE rb_mysql_result_fetch_tables(VALUE self) {
  unsigned int i = 0;

  GET_RESULT(self);

  if (wrapper->tables == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->tables = rb_ary_new2(wrapper->numberOfFields);
  }

  if ((my_ulonglong)RARRAY_LEN(wrapper->tables) != wrapper->numberOfFields) {
    for (i=0; i<wrapper->numberOfFields; i++) {
      rb_mysql_result_fetch_table(self, i);
    }
  }

  return wrapper->tables;
}

static VALUE rb_mysql_result_fetch_dbs(VALUE self) {
  unsigned int i = 0;

  GET_RESULT(self);

  if (wrapper->dbs == Qnil) {
    wrapper->numberOfFields = mysql_num_fields(wrapper->result);
    wrapper->dbs = rb_ary_new2(wrapper->numberOfFields);
  }

  if ((my_ulonglong)RARRAY_LEN(wrapper->dbs) != wrapper->numberOfFields) {
    for (i=0; i<wrapper->numberOfFields; i++) {
      rb_mysql_result_fetch_db(self, i);
    }
  }

  return wrapper->dbs;
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
      // (e.g. KILL QUERY from another session). mysql_error returns an
      // empty string if there is no error.
      errstr = mysql_error(wrapper->client_wrapper->client);
      if (errstr[0]) {
        rb_raise_mysql2_error(wrapper->client_wrapper);
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
  VALUE scratch_holder = 0;
  VALUE rows;
  VALUE opts, (*fetch_row_func)(VALUE, MYSQL_FIELD *fields, const result_each_args *args);
  ID db_timezone, app_timezone;
  int symbolizeKeys, asArray, castBool, cacheRows;
  mysql2_cast_mode cast;
  int warnDbTimezone, perEachOpts;
  unsigned long rowsPerGvlYield;

  GET_RESULT(self);

  if (wrapper->stmt_wrapper && wrapper->stmt_wrapper->closed) {
    rb_raise(cMysql2Error, "Statement handle already closed");
  }

  // A block can be passed to this method, but since we don't call the block directly from C,
  // we don't need to capture it into a variable here with the "&" scan arg.
  perEachOpts = rb_scan_args(argc, argv, "01", &opts) == 1;

  /* :force_encoding is resolved when the query/execute command is issued
   * and is fixed for the life of the Result: non-streaming
   * Statement#execute materializes every row by calling #each itself, so
   * a value passed here could never be honored consistently. Reject it
   * outright rather than silently ignoring it. (The merged defaults
   * below legitimately carry the query-time value; only the per-#each
   * hash is checked.) */
  if (perEachOpts && RB_TYPE_P(opts, T_HASH) && rb_hash_lookup2(opts, sym_force_encoding, Qundef) != Qundef) {
    rb_raise(cMysql2Error, ":force_encoding is a query option and cannot be set on Result#each");
  }

  if (!perEachOpts && wrapper->each_opts.parsed) {
    /* Argument-less #each over the already-parsed @query_options: reuse the
     * parse. Warnings are deliberately not part of the cache -- their
     * conditions are recomputed from the cached (pre-forcing) values below,
     * so they fire on every call exactly as an uncached parse would. */
    symbolizeKeys   = wrapper->each_opts.symbolizeKeys;
    asArray         = wrapper->each_opts.asArray;
    castBool        = wrapper->each_opts.castBool;
    cacheRows       = wrapper->each_opts.cacheRows;
    cast            = wrapper->each_opts.cast;
    warnDbTimezone  = wrapper->each_opts.warnDbTimezone;
    rowsPerGvlYield = wrapper->each_opts.rowsPerGvlYield;
    db_timezone     = wrapper->each_opts.db_timezone;
    app_timezone    = wrapper->each_opts.app_timezone;
  } else {
    VALUE dbTz, appTz, rowsPerGvlYieldOpt, castOpt;
    VALUE defaults = rb_ivar_get(self, intern_query_options);
    Check_Type(defaults, T_HASH);

    opts = perEachOpts ? rb_funcall(defaults, intern_merge, 1, opts) : defaults;

    symbolizeKeys = RTEST(rb_hash_aref(opts, sym_symbolize_keys));
    asArray       = rb_hash_aref(opts, sym_as) == sym_array;
    castBool      = RTEST(rb_hash_aref(opts, sym_cast_booleans));
    cacheRows     = RTEST(rb_hash_aref(opts, sym_cache_rows));

    /* See mysql2_cast_mode: only the exact symbol :fast selects partial
     * casting; any other truthy value stays full casting. */
    castOpt = rb_hash_aref(opts, sym_cast);
    if (castOpt == sym_fast) {
      cast = MYSQL2_CAST_FAST;
    } else if (RTEST(castOpt)) {
      cast = MYSQL2_CAST_ALL;
    } else {
      cast = MYSQL2_CAST_NONE;
    }

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

    /* The timezone lookups are hoisted from their historical spot below the
     * freed-result guard so a complete parse exists to cache; the lookups
     * themselves are side-effect free, and the invalid-:database_timezone
     * warning is deferred (warnDbTimezone) to its historical point, after
     * that guard. */
    dbTz = rb_hash_aref(opts, sym_database_timezone);
    warnDbTimezone = 0;
    if (dbTz == sym_local) {
      db_timezone = intern_local;
    } else if (dbTz == sym_utc) {
      db_timezone = intern_utc;
    } else {
      warnDbTimezone = !NIL_P(dbTz);
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

    if (!perEachOpts) {
      /* Nothing above raised, so this parse of @query_options is complete
       * and can serve every later argument-less call. An invalid
       * :rows_per_gvl_yield raises before this point, leaving the cache
       * unset so the next call re-parses and re-raises just as an uncached
       * one would. */
      wrapper->each_opts.symbolizeKeys   = symbolizeKeys;
      wrapper->each_opts.asArray         = asArray;
      wrapper->each_opts.castBool        = castBool;
      wrapper->each_opts.cacheRows       = cacheRows;
      wrapper->each_opts.cast            = cast;
      wrapper->each_opts.warnDbTimezone  = warnDbTimezone;
      wrapper->each_opts.rowsPerGvlYield = rowsPerGvlYield;
      wrapper->each_opts.db_timezone     = db_timezone;
      wrapper->each_opts.app_timezone    = app_timezone;
      wrapper->each_opts.parsed          = 1;
    }
  }

  if (wrapper->is_streaming && cacheRows) {
    rb_warn(":cache_rows is ignored if :stream is true");
  }

  if (wrapper->stmt_wrapper && !cacheRows && !wrapper->is_streaming) {
    rb_warn(":cache_rows is forced for prepared statements (if not streaming)");
    cacheRows = 1;
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

  if (warnDbTimezone) {
    rb_warn(":database_timezone option must be :utc or :local - defaulting to :local");
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
  /* Captured once per #each call; see the field's comment in
   * result_each_args. */
  args.default_internal_enc = rb_default_internal_encoding();

  /* See the field's comment in result_each_args. A freed result only
   * replays cached rows (or raises), never fetches, so wrapper->result is
   * valid whenever the scratch is allocated -- and the fetch functions only
   * touch the scratch after their own freed-result guards pass. A raise or
   * break during iteration skips the ALLOCV_END below and leaks the
   * heap-allocated form of the buffer until GC reclaims scratch_holder;
   * that is the standard ALLOCV trade, bounded to one buffer per raised
   * iteration because the allocation is per-#each, not per-row. */
  args.rowScratch = NULL;
  if (asArray && !wrapper->resultFreed) {
    args.rowScratch = ALLOCV_N(VALUE, scratch_holder, mysql_num_fields(wrapper->result));
  }

  if (wrapper->stmt_wrapper) {
    fetch_row_func = rb_mysql_result_fetch_row_stmt;
  } else {
    fetch_row_func = rb_mysql_result_fetch_row;
  }

  rows = rb_mysql_result_each_(self, fetch_row_func, &args);
  ALLOCV_END(scratch_holder);

  return rows;
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

/* call-seq:
 *    result.query_time # => Float seconds, or nil
 *
 * The server round trip that produced this result, as observed by the
 * calling thread: seconds from the moment the command was written to the
 * connection until its first response had been fully read, measured in C
 * on a monotonic clock. Server execution and network time to the first
 * response are in; buffering the remaining rows (the store phase), casting
 * values into Ruby objects, and GVL waits after the first response are
 * out. On a quiet process the reading matches the wire; under GVL
 * contention it includes time the thread spent waiting to be rescheduled
 * mid-round-trip, like any thread-observed timing in CRuby. For a query
 * issued with :async the bracket closes inside Client#async_result, so
 * time between the response becoming readable and that call is included.
 * nil when no reading applies -- the second and later result sets of a
 * multi-statement command (Client#store_result).
 */
static VALUE rb_mysql_result_query_time(VALUE self) {
  GET_RESULT(self);
  return wrapper->query_time < 0 ? Qnil : DBL2NUM(wrapper->query_time);
}

/* Mysql2::Result */
VALUE rb_mysql_result_to_obj(VALUE client, VALUE encoding, VALUE options, MYSQL_RES *r, VALUE statement, double query_time) {
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
  wrapper->local_band.lo = 1; /* empty band */
  wrapper->local_band.hi = 0;
  wrapper->local_band.off = 0;
  wrapper->local_band.tz_state = -1; /* no proof yet */
  wrapper->result = r;
  wrapper->fields = Qnil;
  wrapper->fieldTypes = Qnil;
  wrapper->tables = Qnil;
  wrapper->dbs = Qnil;
  wrapper->rows = Qnil;
  wrapper->server_flags = Qnil;
  wrapper->encoding = encoding;
  /* encoding is always the client's Encoding instance (set unconditionally by
   * Client#initialize via charset_name=, before any query can produce a
   * Result), so rb_to_encoding is a plain data unwrap here: no coercion, no
   * allocation, and -- required in this function, which must not raise between
   * taking ownership of r and returning -- no exception path. */
  wrapper->conn_enc = rb_to_encoding(encoding);
  wrapper->streamingComplete = 0;
  wrapper->client = client;
  wrapper->client_wrapper = DATA_PTR(client);
  wrapper->client_wrapper->refcount++;
  /* Capture the connection's server status now, while it still reflects the
   * query that produced this result, so #server_flags can be built lazily.
   * A plain uint copy: cannot raise, per the post-streaming-registration
   * lifecycle rules in client.c/statement.c. */
  wrapper->server_status = wrapper->client_wrapper->client->server_status;
  wrapper->query_time = query_time;
  wrapper->result_buffers = NULL;
  wrapper->result_buffers_bound = 0;
  wrapper->is_null = NULL;
  wrapper->error = NULL;
  wrapper->length = NULL;
  /* Plain assignment only: nothing in this function may raise (post-#1463
   * streaming lifecycle). The parse itself happens in the first
   * argument-less #each. */
  wrapper->each_opts.parsed = 0;

  /* Keep a handle to the Statement to ensure it doesn't get garbage collected first */
  wrapper->statement = statement;
  wrapper->stmt_metadata_epoch = 0;
  wrapper->fields_symbolized = 0;
  if (statement != Qnil) {
    mysql_stmt_wrapper *stmt_wrapper = DATA_PTR(statement);
    wrapper->stmt_wrapper = stmt_wrapper;
    stmt_wrapper->refcount++;
    wrapper->stmt_metadata_epoch = stmt_wrapper->metadata_epoch;

    /* Adopt the artifacts cached from this statement's previous execute;
     * mysql2_stmt_validate_metadata_cache already verified them against
     * this execute's freshly read metadata (dropping them on mismatch), so
     * whatever survives here is shape-compatible. Buffer sizes are
     * data-dependent, not part of that validation: an adopted char[] buffer
     * can be smaller than this result's widest value, and the
     * MYSQL_DATA_TRUNCATED grow-and-refetch path in
     * rb_mysql_result_fetch_row_stmt grows it to fit, exactly as it grows a
     * freshly allocated initial-size buffer. The bind-type election is
     * adopted along with the buffers: when this execute's cast mode wants
     * the other election, the fetch path sees the mismatch and re-elects
     * (frees and reallocates) before binding, exactly as it does for a
     * mid-result #each mode switch. */
    if (stmt_wrapper->cached_result_buffers) {
      wrapper->result_buffers = stmt_wrapper->cached_result_buffers;
      wrapper->is_null = stmt_wrapper->cached_is_null;
      wrapper->error = stmt_wrapper->cached_error;
      wrapper->length = stmt_wrapper->cached_length;
      wrapper->result_buffers_string_binds = stmt_wrapper->cached_result_buffers_string_binds;
      wrapper->numberOfFields = stmt_wrapper->cached_field_count;
      stmt_wrapper->cached_result_buffers = NULL;
      stmt_wrapper->cached_is_null = NULL;
      stmt_wrapper->cached_error = NULL;
      stmt_wrapper->cached_length = NULL;
    }

    /* Field names are adopted only for a non-streaming Result (a streaming
     * one materializes names under its first #each's options, which may
     * differ from these) and only when they were built under the same
     * :symbolize_keys. The cache keeps its private master copy; this Result
     * gets a dup, so mutations of #fields stay its own. */
    if (stmt_wrapper->cached_fields != Qnil &&
        rb_hash_aref(options, sym_stream) != Qtrue &&
        stmt_wrapper->cached_fields_symbolized == (RTEST(rb_hash_aref(options, sym_symbolize_keys)) ? 1 : 0)) {
      wrapper->fields = rb_ary_dup(stmt_wrapper->cached_fields);
      wrapper->fields_symbolized = stmt_wrapper->cached_fields_symbolized;
      wrapper->numberOfFields = stmt_wrapper->cached_field_count;
    }
  } else {
    wrapper->stmt_wrapper = NULL;
  }

  rb_obj_call_init(obj, 0, NULL);
  rb_ivar_set(obj, intern_query_options, options);

  /* Options that cannot be changed in results.each(...) { |row| }
   * should be processed here. */
  /* Both streaming spellings: stream: true, and stream: {size: N} (already
   * validated at the execute entry point; only Statement#execute lets the
   * hash form through). Any other value -- including other truthy ones --
   * means the query ran buffered, so this test must match the execute-side
   * predicate exactly or the fetch path desyncs from the protocol state. */
  {
    VALUE stream = rb_hash_aref(options, sym_stream);
    wrapper->is_streaming = (stream == Qtrue || RB_TYPE_P(stream, T_HASH)) ? 1 : 0;
  }

  /* :force_encoding was canonicalized to an Encoding object at the
   * query/execute entry point (mysql2_canonicalize_force_encoding), so
   * rb_to_encoding here is a plain data unwrap with no exception path --
   * required in this function, see conn_enc above. */
  {
    VALUE forced = rb_hash_aref(options, sym_force_encoding);
    wrapper->forced_enc = NIL_P(forced) ? NULL : rb_to_encoding(forced);
  }

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

  /* True when this build constructs :local DATETIME values without the
   * per-cell Time.local funcall (needs rb_time_timespec_new, localtime_r,
   * and struct tm.tm_gmtoff). Behavior is identical either way; the
   * constant lets tests and diagnostics tell which path a platform runs. */
#ifdef MYSQL2_LOCAL_FAST_PATH
  rb_define_const(cMysql2Result, "LOCAL_DATETIME_FAST_PATH", Qtrue);
#else
  rb_define_const(cMysql2Result, "LOCAL_DATETIME_FAST_PATH", Qfalse);
#endif
  rb_define_method(cMysql2Result, "fields", rb_mysql_result_fetch_fields, 0);
  rb_define_method(cMysql2Result, "tables", rb_mysql_result_fetch_tables, 0);
  rb_define_method(cMysql2Result, "dbs", rb_mysql_result_fetch_dbs, 0);
  rb_define_method(cMysql2Result, "field_types", rb_mysql_result_fetch_field_types, 0);
  rb_define_method(cMysql2Result, "free", rb_mysql_result_free_, 0);
  rb_define_method(cMysql2Result, "count", rb_mysql_result_count, 0);
  rb_define_method(cMysql2Result, "server_flags", rb_mysql_result_server_flags, 0);
  rb_define_method(cMysql2Result, "query_time", rb_mysql_result_query_time, 0);
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
  intern_query_options = rb_intern("@query_options");
  intern_plus         = rb_intern("+");

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
  sym_fast           = ID2SYM(rb_intern("fast"));
  sym_stream         = ID2SYM(rb_intern("stream"));
  sym_name           = ID2SYM(rb_intern("name"));
  sym_no_good_index_used = ID2SYM(rb_intern("no_good_index_used"));
  sym_no_index_used      = ID2SYM(rb_intern("no_index_used"));
  sym_query_was_slow     = ID2SYM(rb_intern("query_was_slow"));
  sym_force_encoding = ID2SYM(rb_intern("force_encoding"));

  opt_decimal_zero = rb_str_new2("0.0");
  rb_global_variable(&opt_decimal_zero); /*never GC */
  opt_float_zero = rb_float_new((double)0);
  rb_global_variable(&opt_float_zero);
  opt_time_year = INT2NUM(2000);
  opt_time_month = INT2NUM(1);
  opt_time_day = INT2NUM(1);
  opt_utc_offset = INT2NUM(0);

  /* mysql2_time_from_duration's :utc anchor, cached here; :local is
   * rebuilt per call there. */
  opt_time_anchor_utc = rb_funcall(rb_cTime, intern_utc, 7, opt_time_year, opt_time_month, opt_time_day,
                                   INT2FIX(0), INT2FIX(0), INT2FIX(0), INT2FIX(0));
  rb_global_variable(&opt_time_anchor_utc); /* never GC */

  binaryEncoding = rb_enc_find("binary");
}
