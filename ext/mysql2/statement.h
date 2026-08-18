#ifndef MYSQL2_STATEMENT_H
#define MYSQL2_STATEMENT_H

/* Per-field snapshot of the result metadata that a statement's cached
 * artifacts were derived from. Metadata itself is re-read from the server's
 * response on every execute (it goes stale under ALTER TABLE); this snapshot
 * exists only to tell whether the artifacts built from the previous execute's
 * metadata are still compatible. max_length is deliberately absent: it is
 * data-dependent per execute, and buffer sizing differences are handled by
 * the grow-to-fit fetch path in result.c instead. */
typedef struct {
  char *name;                 /* xmalloc'd copy of the field name bytes */
  unsigned long name_length;
  enum enum_field_types type;
  unsigned int flags;
  unsigned int charsetnr;
} mysql2_stmt_field_meta;

typedef struct {
  VALUE client;
  MYSQL_STMT *stmt;
  mysql_client_wrapper *client_wrapper;
  int refcount;
  int closed;
  /* Cross-execute cache of metadata-derived artifacts, validated against
   * freshly read metadata by mysql2_stmt_validate_metadata_cache on every
   * execute and adopted by the new Result in rb_mysql_result_to_obj. A
   * Result hands its artifacts back when it is freed (result.c,
   * rb_mysql_result_free_result). metadata_epoch increments whenever the
   * snapshot is rebuilt, so a Result created under an older snapshot can
   * tell its artifacts no longer match the current shape and must not be
   * handed back. cached_fields is a private master copy that is never
   * returned to Ruby callers: each adopting Result receives a dup, so
   * mutations of Result#fields cannot reach the cache. It is marked (and
   * compacted) via rb_mysql_stmt_mark/rb_mysql_stmt_compact. */
  unsigned int cached_field_count;
  mysql2_stmt_field_meta *cached_field_meta;
  unsigned long metadata_epoch;
  VALUE cached_fields;
  int cached_fields_symbolized;
  int cached_fields_downcased;
  MYSQL_BIND *cached_result_buffers;
  my_bool *cached_is_null;
  my_bool *cached_error;
  unsigned long *cached_length;
  /* The bind-type election the cached buffers were built under (see
   * result_buffers_string_binds in result.h), recorded when they are handed
   * back and restored when they are adopted. Meaningful only while
   * cached_result_buffers is non-NULL. An execute whose cast mode wants the
   * other election adopts and then re-elects at fetch time, so the election
   * is deliberately not part of cache validation: it can never decode
   * values through the wrong types, only miss the cache. */
  char cached_result_buffers_string_binds;
} mysql_stmt_wrapper;

void init_mysql2_statement(void);
void decr_mysql2_stmt(mysql_stmt_wrapper *stmt_wrapper);

VALUE rb_mysql_stmt_new(VALUE rb_client, VALUE sql);
void rb_raise_mysql2_stmt_error(mysql_stmt_wrapper *stmt_wrapper) RB_MYSQL_NORETURN;

#endif
