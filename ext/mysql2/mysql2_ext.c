#include <mysql2_ext.h>

VALUE mMysql2, cMysql2Error, intern_encoding_from_charset;
ID    sym_id, sym_version, sym_async, sym_symbolize_keys, sym_as, sym_array;
ID    intern_merge;

/* Ruby Extension initializer */
void Init_mysql2() {
  mMysql2      = rb_define_module("Mysql2");
  cMysql2Error = rb_const_get(mMysql2, rb_intern("Error"));

  intern_merge = rb_intern("merge");

  sym_array           = ID2SYM(rb_intern("array"));
  sym_as              = ID2SYM(rb_intern("as"));
  sym_id              = ID2SYM(rb_intern("id"));
  sym_version         = ID2SYM(rb_intern("version"));
  sym_async           = ID2SYM(rb_intern("async"));
  sym_symbolize_keys  = ID2SYM(rb_intern("symbolize_keys"));

  intern_encoding_from_charset = rb_intern("encoding_from_charset");

  init_mysql2_client();
  init_mysql2_result();
}
