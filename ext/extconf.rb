# encoding: UTF-8

require 'mkmf'
dir_config('mysql')

have_header('mysql/mysql.h')

$CFLAGS << ' -Wall -Wextra -funroll-loops'
$CFLAGS << ' -O0 -ggdb3'

if have_library('mysqlclient')
  if RUBY_VERSION =~ /1.9/
    $CFLAGS << ' -DRUBY_19_COMPATIBILITY'
  end
  
  create_makefile('mysql_duce_ext')
else
  puts 'libmysql not found, maybe try manually specifying --with-mysql-lib to find it?'
end