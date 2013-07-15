# encoding: UTF-8
require 'mkmf'

def asplode lib
  abort "-----\n#{lib} is missing.  please check your installation of mysql and try again.\n-----"
end

# 1.9-only
have_func('rb_thread_blocking_region')
have_func('rb_wait_for_single_fd')
have_func('rb_hash_dup')
have_func('rb_intern3')

# borrowed from mysqlplus
# http://github.com/oldmoe/mysqlplus/blob/master/ext/extconf.rb
dirs = ENV['PATH'].split(File::PATH_SEPARATOR) + %w[
  /opt
  /opt/local
  /opt/local/mysql
  /opt/local/lib/mysql5
  /usr
  /usr/mysql
  /usr/local
  /usr/local/mysql
  /usr/local/mysql-*
  /usr/local/lib/mysql5
].map{|dir| "#{dir}/bin" }

GLOB = "{#{dirs.join(',')}}/{mysql_config,mysql_config5}"

if RUBY_PLATFORM =~ /mswin|mingw/
  inc, lib = dir_config('mysql')

  # Ruby versions not incorporating the mkmf fix at
  # https://bugs.ruby-lang.org/projects/ruby-trunk/repository/revisions/39717
  # do not properly search for lib directories, and must be corrected
  unless lib[-3, 3] == 'lib'
    @libdir_basename = 'lib'
    inc, lib = dir_config('mysql')
  end
  exit 1 unless have_library("libmysql")
elsif mc = (with_config('mysql-config') || Dir[GLOB].first) then
  mc = Dir[GLOB].first if mc == true
  ver = `#{mc} --version`.chomp.to_f
  cflags = `#{mc} --cflags`.chomp
  exit 1 if $? != 0
  libs = `#{mc} --libs_r`.chomp
  # MySQL 5.5 and above already have re-entrant code in libmysqlclient (no _r).
  if ver >= 5.5 || libs.empty?
    libs = `#{mc} --libs`.chomp
  end
  exit 1 if $? != 0
  $CPPFLAGS += ' ' + cflags
  $libs = libs + " " + $libs
else
  inc, lib = dir_config('mysql', '/usr/local')
  libs = ['m', 'z', 'socket', 'nsl', 'mygcc']
  while not find_library('mysqlclient', 'mysql_query', lib, "#{lib}/mysql") do
    exit 1 if libs.empty?
    have_library(libs.shift)
  end
end

if have_header('mysql.h') then
  prefix = nil
elsif have_header('mysql/mysql.h') then
  prefix = 'mysql'
else
  asplode 'mysql.h'
end

%w{ errmsg.h mysqld_error.h }.each do |h|
  header = [prefix, h].compact.join '/'
  asplode h unless have_header h
end

# GCC specific flags
if RbConfig::MAKEFILE_CONFIG['CC'] =~ /gcc/
  $CFLAGS << ' -Wall -funroll-loops'

  if libdir = $libs[%r{-L(/[^ ]+)}, 1]
    # The following comment and test is borrowed from the Pg gem:
    # Try to use runtime path linker option, even if RbConfig doesn't know about it.
    # The rpath option is usually set implicit by dir_config(), but so far not on Mac OS X.
    if RbConfig::CONFIG["RPATHFLAG"].to_s.empty? && try_link('int main() {return 0;}', " -Wl,-rpath,#{libdir}")
      $LDFLAGS << " -Wl,-rpath,#{libdir}"
    end
  end
end

create_makefile('mysql2/mysql2')
