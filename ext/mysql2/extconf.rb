# encoding: UTF-8
require 'mkmf'

class Platform
  # Gets the proper platform object for the current platform.
  def self.current
    case RUBY_PLATFORM
      when /mswin/
        Windows.new
      when /mingw/
        WindowsMingw.new
      when /darwin/
        MacOS.new
      else
        Linux.new
    end
  end

  def configure
    _, @rpath_dir = detect_paths
    detect_headers
    detect_libraries

    configure_compiler
  end

  protected

  def rpath_dir
    @rpath_dir
  end

  # @return [(String, String)|nil] The include and library paths.
  def detect_paths
    detect_by_explicit_path || detect_by_mysql_config
  end

  def detect_headers
    headers = %w{ errmsg.h mysqld_error.h }
    prefix = ['', 'mysql/'].find do |prefix|
      have_header("#{prefix}mysql.h")
    end
    asplode('mysql.h') unless prefix

    headers.each do |header|
      header = "#{prefix}#{header}"
      asplode(header) unless have_header(header)
    end
  end

  def detect_libraries
    libraries = %w{ mysqlclient libmysql }
    library = libraries.find do |library|
      have_library(library, 'mysql_query')
    end

    asplode 'mysqlclient or libmysql' unless library
  end

  def configure_compiler
    # These gcc style flags are also supported by clang and xcode compilers,
    # so we'll use a does-it-work test instead of an is-it-gcc test.
    gcc_flags = ' -Wall -funroll-loops'
    if try_link('int main() {return 0;}', gcc_flags)
      $CFLAGS << gcc_flags
    end
  end

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
    if mysql_config_path
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
    else
      error 'Cannot find mysql_config' if with_config('mysql-config')
      nil
    end
  end

  def error(message)
    abort("-----\n#{message}\n-----")
  end

  def warn(message)
    super("-----\n#{message}\n-----")
  end

  def asplode(library)
    error("#{library} is missing. #{asplode_suggestion}")
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

  def configure
    super

    case explicit_rpath = with_config('mysql-rpath')
    when true
      error 'Option --with-mysql-rpath must have an argument'
    when false
      error 'Option --with-mysql-rpath has been disabled at your request'
    when String
      # The user gave us a value so use it
      rpath_flags = " -Wl,-rpath,#{explicit_rpath}"
      warn "Setting mysql rpath to #{explicit_rpath}"
      $LDFLAGS << rpath_flags
    else
      if libdir = rpath_dir[%r{(-L)?(/[^ ]+)}, 2]
        rpath_flags = " -Wl,-rpath,#{libdir}"
        if RbConfig::CONFIG['RPATHFLAG'].to_s.empty? && try_link('int main() {return 0;}', rpath_flags)
          # Usually Ruby sets RPATHFLAG the right way for each system, but not on OS X.
          warn "Setting rpath to #{libdir}"
          $LDFLAGS << rpath_flags
        else
          if RbConfig::CONFIG['RPATHFLAG'].to_s.empty?
            # If we got here because try_link failed, warn the user
            warn 'Don\'t know how to set rpath on your system, if MySQL '\
              'libraries are not in path mysql2 may not load'
          end
          # Make sure that LIBPATH gets set if we didn't explicitly set the rpath.
          warn "Setting libpath to #{libdir}"
          $LIBPATH << libdir unless $LIBPATH.include?(libdir)
        end
      end
    end
  end

  protected

  def detect_paths
    super || detect_by_known_paths
  end

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
  def configure
    super

    require 'rake'

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
      puts '--no-vendor-libmysql'
    else # Default: arg_config('--vendor-libmysql')
      # Let's do it!
      Rake::Task[vendordll].invoke
    end
  end
end

class WindowsMingw < Windows
  def configure
    super

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
      error 'Cannot find libmysql.a' unless have_library('libmysql')
      error 'Cannot link to libmysql.a (my_init)' unless have_func('my_init')
    end
  end
end

# 2.0-only
have_header('ruby/thread.h') && have_func('rb_thread_call_without_gvl', 'ruby/thread.h')

# 1.9-only
have_func('rb_thread_blocking_region')
have_func('rb_wait_for_single_fd')
have_func('rb_hash_dup')
have_func('rb_intern3')

Platform.current.configure

create_makefile('mysql2/mysql2')
