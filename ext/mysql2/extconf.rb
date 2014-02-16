# encoding: UTF-8
require 'mkmf'

def asplode lib
  abort "-----\n#{lib} is missing.  please check your installation of mysql and try again.\n-----"
end

# 2.0-only
have_header('ruby/thread.h') && have_func('rb_thread_call_without_gvl', 'ruby/thread.h')

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

# If the user has provided a --with-mysql-dir argument, we must respect it or fail.
inc, lib = dir_config('mysql')
if inc && lib
  # Ruby versions not incorporating the mkmf fix at
  # https://bugs.ruby-lang.org/projects/ruby-trunk/repository/revisions/39717
  # do not properly search for lib directories, and must be corrected
  unless lib && lib[-3, 3] == 'lib'
    @libdir_basename = 'lib'
    inc, lib = dir_config('mysql')
  end
  abort "-----\nCannot find include dir(s) #{inc}\n-----" unless inc && inc.split(File::PATH_SEPARATOR).any?{|dir| File.directory?(dir)}
  abort "-----\nCannot find library dir(s) #{lib}\n-----" unless lib && lib.split(File::PATH_SEPARATOR).any?{|dir| File.directory?(dir)}
  warn  "-----\nUsing --with-mysql-dir=#{File.dirname inc}\n-----"
  rpath_dir = lib
elsif mc = (with_config('mysql-config') || Dir[GLOB].first)
  # If the user has provided a --with-mysql-config argument, we must respect it or fail.
  # If the user gave --with-mysql-config with no argument means we should try to find it.
  mc = Dir[GLOB].first if mc == true
  abort "-----\nCannot find mysql_config at #{mc}\n-----" unless mc && File.exists?(mc)
  abort "-----\nCannot execute mysql_config at #{mc}\n-----" unless File.executable?(mc)
  warn  "-----\nUsing mysql_config at #{mc}\n-----"
  ver = `#{mc} --version`.chomp.to_f
  includes = `#{mc} --include`.chomp
  exit 1 if $? != 0
  libs = `#{mc} --libs_r`.chomp
  # MySQL 5.5 and above already have re-entrant code in libmysqlclient (no _r).
  if ver >= 5.5 || libs.empty?
    libs = `#{mc} --libs`.chomp
  end
  exit 1 if $? != 0
  $INCFLAGS += ' ' + includes
  $libs = libs + " " + $libs
  rpath_dir = libs
else
  inc, lib = dir_config('mysql', '/usr/local')
  libs = ['m', 'z', 'socket', 'nsl', 'mygcc']
  while not find_library('mysqlclient', 'mysql_query', lib, "#{lib}/mysql") do
    exit 1 if libs.empty?
    have_library(libs.shift)
  end
  rpath_dir = lib
end

if RUBY_PLATFORM =~ /mswin|mingw/
  exit 1 unless have_library('libmysql')
end

if have_header('mysql.h')
  prefix = nil
elsif have_header('mysql/mysql.h')
  prefix = 'mysql'
else
  asplode 'mysql.h'
end

%w{ errmsg.h mysqld_error.h }.each do |h|
  header = [prefix, h].compact.join '/'
  asplode h unless have_header h
end

# These gcc style flags are also supported by clang and xcode compilers,
# so we'll use a does-it-work test instead of an is-it-gcc test.
gcc_flags = ' -Wall -funroll-loops'
if try_link('int main() {return 0;}', gcc_flags)
  $CFLAGS << gcc_flags
end

case explicit_rpath = with_config('mysql-rpath')
when true
  abort "-----\nOption --with-mysql-rpath must have an argument\n-----"
when false
  warn "-----\nOption --with-mysql-rpath has been disabled at your request\n-----"
when String
  # The user gave us a value so use it
  rpath_flags = " -Wl,-rpath,#{explicit_rpath}"
  warn "-----\nSetting mysql rpath to #{explicit_rpath}\n-----"
  $LDFLAGS << rpath_flags
else
  if libdir = rpath_dir[%r{(-L)?(/[^ ]+)}, 2]
    rpath_flags = " -Wl,-rpath,#{libdir}"
    if RbConfig::CONFIG["RPATHFLAG"].to_s.empty? && try_link('int main() {return 0;}', rpath_flags)
      # Usually Ruby sets RPATHFLAG the right way for each system, but not on OS X.
      warn "-----\nSetting rpath to #{libdir}\n-----"
      $LDFLAGS << rpath_flags
    else
      if RbConfig::CONFIG["RPATHFLAG"].to_s.empty?
        # If we got here because try_link failed, warn the user
        warn "-----\nDon't know how to set rpath on your system, if MySQL libraries are not in path mysql2 may not load\n-----"
      end
      # Make sure that LIBPATH gets set if we didn't explicitly set the rpath.
      warn "-----\nSetting libpath to #{libdir}\n-----"
      $LIBPATH << libdir unless $LIBPATH.include?(libdir)
    end
  end
end

create_makefile('mysql2/mysql2')
