# encoding: UTF-8
require 'mkmf'

def asplode lib
  if RUBY_PLATFORM =~ /mingw|mswin/
    abort "-----\n#{lib} is missing. Check your installation of MySQL or Connector/C, and try again.\n-----"
  elsif RUBY_PLATFORM =~ /darwin/
    abort "-----\n#{lib} is missing. You may need to 'brew install mysql' or 'port install mysql', and try again.\n-----"
  else
    abort "-----\n#{lib} is missing. You may need to 'apt-get install libmysqlclient-dev' or 'yum install mysql-devel', and try again.\n-----"
  end
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
  /opt/local/lib/mysql5*
  /usr
  /usr/mysql
  /usr/local
  /usr/local/mysql
  /usr/local/mysql-*
  /usr/local/lib/mysql5*
].map{|dir| "#{dir}/bin" }

GLOB = "{#{dirs.join(',')}}/{mysql_config,mysql_config5,mariadb_config}"

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
  unless find_library('mysqlclient', 'mysql_query', lib, "#{lib}/mysql")
    found = false
    # For some systems and some versions of libmysqlclient, there were extra
    # libraries needed to link. Try each typical extra library, add it to the
    # global compile flags, and see if that allows us to link libmysqlclient.
    warn "-----\nlibmysqlclient is missing. Trying again with extra runtime libraries...\n-----"

    %w{ m z socket nsl mygcc }.each do |extra_lib|
      if have_library(extra_lib) && find_library('mysqlclient', 'mysql_query', lib, "#{lib}/mysql")
        found = true
        break
      end
    end
    asplode('libmysqlclient') unless found
  end

  rpath_dir = lib
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

if RUBY_PLATFORM =~ /mswin|mingw/
  # Build libmysql.a interface link library
  require 'rake'

  # Build libmysql.a interface link library
  # Use rake to rebuild only if these files change
  deffile = File.expand_path('../../../support/libmysql.def', __FILE__)
  libfile = File.expand_path(File.join(rpath_dir, 'libmysql.lib'))
  file 'libmysql.a' => [deffile, libfile] do |t|
    when_writing 'building libmysql.a' do
      # Ruby kindly shows us where dllwrap is, but that tool does more than we want.
      # Maybe in the future Ruby could provide RbConfig::CONFIG['DLLTOOL'] directly.
      dlltool = RbConfig::CONFIG['DLLWRAP'].gsub('dllwrap', 'dlltool')
      sh dlltool, '--kill-at',
         '--dllname', 'libmysql.dll',
         '--output-lib', 'libmysql.a',
         '--input-def', deffile, libfile
    end
  end

  Rake::Task['libmysql.a'].invoke
  $LOCAL_LIBS << ' ' << 'libmysql.a'

  # Make sure the generated interface library works (if cross-compiling, trust without verifying)
  unless RbConfig::CONFIG['host_os'] =~ /mswin|mingw/
    abort "-----\nCannot find libmysql.a\n----" unless have_library('libmysql')
    abort "-----\nCannot link to libmysql.a (my_init)\n----" unless have_func('my_init')
  end

  # Vendor libmysql.dll
  vendordir = File.expand_path('../../../vendor/', __FILE__)
  directory vendordir

  vendordll = File.join(vendordir, 'libmysql.dll')
  dllfile = File.expand_path(File.join(rpath_dir, 'libmysql.dll'))
  file vendordll => [dllfile, vendordir] do |t|
    when_writing 'copying libmysql.dll' do
      cp dllfile, vendordll
    end
  end

  # Copy libmysql.dll to the local vendor directory by default
  if arg_config('--no-vendor-libmysql')
    # Fine, don't.
    puts "--no-vendor-libmysql"
  else # Default: arg_config('--vendor-libmysql')
    # Let's do it!
    Rake::Task[vendordll].invoke
  end
else
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
end

create_makefile('mysql2/mysql2')
