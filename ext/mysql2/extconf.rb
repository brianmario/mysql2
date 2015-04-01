# encoding: UTF-8
require 'mkmf'

class Platform
  # Gets the proper platform object for the current platform.
  def self.current
    case RUBY_PLATFORM
      when /mswin|mingw/
        Windows.new
      when /darwin/
        MacOS.new
      else
        Linux.new
    end
  end

  # @return [(String, String)|nil] The include and library paths.
  def detect_paths
    detect_by_explicit_path || detect_by_mysql_config
  end

  protected

  def detect_by_explicit_path
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

      error "Cannot find include dir(s) #{inc}" unless inc && inc.split(File::PATH_SEPARATOR).any?{|dir| File.directory?(dir)}
      error "Cannot find library dir(s) #{lib}" unless lib && lib.split(File::PATH_SEPARATOR).any?{|dir| File.directory?(dir)}
      warn  "Using --with-mysql-dir=#{File.dirname(inc)}"
      [inc, lib]
    else
      nil
    end
  end

  def detect_by_mysql_config
    if with_config('mysql-config') && !mysql_config_path
      error 'Cannot find mysql_config'
    end
    warn  "Using mysql_config at #{mysql_config_path}"

    ver = `#{mysql_config_path} --version`.chomp.to_f
    includes = `#{mysql_config_path} --include`.chomp
    exit 1 if $? != 0
    libs = `#{mysql_config_path} --libs_r`.chomp

    # MySQL 5.5 and above already have re-entrant code in libmysqlclient (no _r).
    if ver >= 5.5 || libs.empty?
      libs = `#{mysql_config_path} --libs`.chomp
    end
    exit 1 if $? != 0

    $INCFLAGS += ' ' + includes
    $libs = "#{libs} #{$libs}"
    [includes, libs]
  end

  def error(message)
    abort("-----\n#{message}\n-----")
  end

  def warn(message)
    super("-----\n#{message}\n-----")
  end

  def asplode(library)
    complain("#{library} is missing. #{asplode_suggestion}")
  end

  def asplode_suggestion
    'Please check your installation of MySQL and try again.'
  end

  def mysql_config_path
    nil
  end
end

class Unix < Platform
  # borrowed from mysqlplus
  # http://github.com/oldmoe/mysqlplus/blob/master/ext/extconf.rb
  DEFAULT_MYSQL_CONFIG_SEARCH_PATHS = %w[
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
  ].freeze

  def detect_paths
    super || detect_by_known_paths
  end

  protected

  def detect_by_known_paths
    inc, lib = dir_config('mysql', '/usr/local')
    libs = ['m', 'z', 'socket', 'nsl', 'mygcc']
    found = false
    until find_library('mysqlclient', 'mysql_query', lib, "#{lib}/mysql") do
      break if libs.empty?
      found ||= have_library(libs.shift)
    end

    asplode('mysql client') unless found

    [inc, lib]
  end

  def default_mysql_config_search_path
    ENV['PATH'].split(File::PATH_SEPARATOR) +
      DEFAULT_MYSQL_CONFIG_SEARCH_PATHS.map{|dir| "#{dir}/bin" }
  end

  def mysql_config_glob
    "{#{default_mysql_config_search_path.join(',')}}/{mysql_config,mysql_config5}"
  end

  def mysql_config_path
    @mysql_config_path ||= Dir[mysql_config_glob].first
  end
end

class Linux < Unix
  protected

  def asplode_suggestion
    'Try `apt-get install libmysqlclient-dev` or `yum install mysql-devel`, '\
    'check your installation of MySQL and try again.'
  end
end

class MacOS < Unix
  protected

  def asplode_suggestion
    'Try `brew install mysql`, check your installation of MySQL and try again.'
  end
end

class Windows < Platform

end

# 2.0-only
have_header('ruby/thread.h') && have_func('rb_thread_call_without_gvl', 'ruby/thread.h')

# 1.9-only
have_func('rb_thread_blocking_region')
have_func('rb_wait_for_single_fd')
have_func('rb_hash_dup')
have_func('rb_intern3')

_, rpath_dir = Platform.current.detect_paths

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

  # This is our wishlist. We use whichever flags work on the host.
  # -Wall and -Wextra are included by default.
  # TODO: fix statement.c and remove -Wno-error=declaration-after-statement
  %w(
    -Werror
    -Weverything
    -fsanitize=address
    -fsanitize=integer
    -fsanitize=thread
    -fsanitize=memory
    -fsanitize=undefined
    -fsanitize=cfi
    -Wno-error=declaration-after-statement
  ).each do |flag|
    if try_link('int main() {return 0;}', flag)
      $CFLAGS << ' ' << flag
    end
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
