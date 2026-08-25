#ifndef MYSQL2_RESULT_H
#define MYSQL2_RESULT_H

void init_mysql2_result(void);
/* query_time is the round trip that produced this result in seconds
 * (Result#query_time); pass a negative value when no reading applies. */
VALUE rb_mysql_result_to_obj(VALUE client, VALUE encoding, VALUE options, MYSQL_RES *r, VALUE statement, double query_time);

/* Resolve a :force_encoding query option (an Encoding object or an encoding
 * name) to its Encoding object, in place in the given options hash, raising
 * ArgumentError/TypeError for invalid values. Called at the query/execute
 * entry points (client.c, statement.c) BEFORE the command is sent, for two
 * reasons: rb_mysql_result_to_obj must not raise between taking ownership of
 * the MYSQL_RES and returning (the streaming lifecycle depends on it), so
 * validation cannot wait until then; and raising pre-send leaves the
 * connection untouched and immediately reusable. Storing the resolved
 * Encoding back into the per-query options snapshot also insulates the
 * Result from later mutation of the value the caller passed. */
void mysql2_canonicalize_force_encoding(VALUE opts);

/* Force-free a Result's underlying MYSQL_RES/MYSQL_STMT result right now,
 * from ordinary Ruby-level code (not a dfree callback) -- so this performs
 * the real mysql_free_result()/mysql_stmt_free_result() call directly
 * rather than deferring it. Used to drain an abandoned streaming cursor
 * that's still live (not yet collected by GC) before the next command --
 * see mysql2_abandon_active_stream in client.c. No-op if already freed. */
void mysql2_result_force_free(VALUE self);

/* Parsed form of the stored @query_options hash, filled in by the first
 * argument-less #each and reused by later argument-less calls so they skip
 * the per-call hash lookups. Plain C scalars and static symbol IDs only --
 * nothing here is a heap VALUE, so no GC marking is needed. A call that
 * passes per-each options neither reads nor writes this cache.
 *
 * cacheRows is stored as parsed, before the prepared-statement forcing in
 * #each, so the warning and forcing replay identically on every call
 * whether the parse was cached or not. warnDbTimezone records that the
 * invalid-:database_timezone warning must be re-issued (each warns every
 * call, and the warning point is after the freed-result guard). */
typedef struct {
  int parsed;
  int symbolizeKeys;
  int asArray;
  int castBool;
  int cacheRows;
  int cast;
  int warnDbTimezone;
  unsigned long rowsPerGvlYield;
  ID db_timezone;
  ID app_timezone; /* Qnil when no conversion applies, as in result_each_args */
} mysql2_each_opts_cache;

/* One proven timezone-offset band for the :local DATETIME fast path: within
 * [lo, hi] the zone offset is known to be off, proven under the TZ value
 * described by tz_state (-1: no proof yet; 0: proven with TZ unset; 1:
 * proven under the string in tz). Empty when lo > hi. */
typedef struct {
  time_t lo;
  time_t hi;
  long off;
  int tz_state;
  char tz[64];
} mysql2_local_band;

typedef struct {
  VALUE fields;
  VALUE fieldTypes;
  VALUE tables;
  VALUE dbs;
  VALUE rows;
  VALUE client;
  VALUE encoding;
  VALUE statement;
  /* Memoized #server_flags Hash, Qnil until first access. Marked (and
   * compacted) alongside the other VALUEs above. */
  VALUE server_flags;
  /* The connection's encoding, unwrapped once at Result creation.
   * wrapper->encoding is fixed at connect time (Client#initialize always
   * runs charset_name=), so this never goes stale; caching it avoids a
   * rb_to_encoding() call per row fetch. */
  rb_encoding *conn_enc;
  /* :local DATETIME fast-path offset-band cache; owned by this result so
   * concurrently iterated results never evict each other's proof. See
   * mysql2_local_time in result.c. */
  mysql2_local_band local_band;
  /* The :force_encoding query option, unwrapped once at Result creation;
   * NULL when the option wasn't given. When set, string values are retagged
   * with this encoding -- bytes unchanged -- instead of taking the
   * per-charset lookup, the binary branch, or the default_internal
   * conversion. */
  rb_encoding *forced_enc;
  /* Seconds from the command being written to its first response being
   * fully read, measured on a monotonic clock by the query/execute path;
   * negative when no reading applies (e.g. Client#store_result results).
   * Exposed as #query_time. */
  double query_time;
  my_ulonglong numberOfFields;
  my_ulonglong numberOfRows;
  unsigned long lastRowProcessed;
  char is_streaming;
  char streamingComplete;
  char resultFreed;
  MYSQL_RES *result;
  mysql_stmt_wrapper *stmt_wrapper;
  mysql_client_wrapper *client_wrapper;
  /* Connection server status captured at Result creation, so #server_flags
   * can be built lazily without reading (possibly since-changed) live
   * connection state. */
  unsigned int server_status;
  /* statement result bind buffers */
  char result_buffers_bound;
  /* Whether result_buffers were elected as MYSQL_TYPE_STRING binds (cast:
   * false / :fast) rather than server-type binds (cast: true). Consulted on
   * every fetch so a later #each with the other cast mode frees and
   * re-elects the buffers instead of decoding through the wrong types. */
  char result_buffers_string_binds;
  MYSQL_BIND *result_buffers;
  my_bool *is_null;
  my_bool *error;
  unsigned long *length;
  /* The statement's metadata_epoch when this Result was created. Cached
   * artifacts are only handed back to the statement while its epoch still
   * matches: an intervening execute may have rebuilt the snapshot around a
   * different shape (ALTER TABLE), and buffers bound for the old shape would
   * silently convert or truncate the new one. 0 and unused without a
   * statement. */
  unsigned long stmt_metadata_epoch;
  /* Whether wrapper->fields holds symbolized names, recorded as they are
   * built so the statement cache can refuse to reuse the array for an
   * execute with a different :symbolize_keys. */
  int fields_symbolized;
  mysql2_each_opts_cache each_opts;
} mysql2_result_wrapper;

#endif
