# encoding: UTF-8
require 'mkmf'

dir_config('mysql')

if !have_header('mysql.h') && !have_header('mysql/mysql.h')
  raise 'MySQL headers not found, maybe try manually specifying --with-mysql=/path/to/mysql/installation'
end

$CFLAGS << ' -Wall -Wextra -funroll-loops'
# $CFLAGS << ' -O0 -ggdb3'

if have_library('mysqlclient')
  if RUBY_VERSION =~ /1.9/
    $CFLAGS << ' -DRUBY_19_COMPATIBILITY'
  end

  create_makefile('mysql2_ext')
else
  raise 'libmysql not found, maybe try manually specifying --with-mysql-lib=/path/to/mysql/libs'
end