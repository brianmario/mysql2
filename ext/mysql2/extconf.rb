# encoding: UTF-8
require 'mkmf'
require 'English'

# Disable these cops, because they make the build script _harder_ to read.
# rubocop:disable Metrics/ClassLength, Style/GuardClause

# For compatibility with Ruby 1.8 and Ruby EE, whose Rake breaks Object#rm_f
class << self
   alias_method :rm_f_original, :rm_f
   require 'rake'
   alias_method :rm_f, :rm_f_original
end

# Represents the base configuration for all platforms.
class Platform
  attr_accessor :rpath_dir

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

  # @return [(String, String)|nil] The include and library paths.
  def detect_paths
    detect_by_explicit_path || detect_by_mysql_config
  end

  def detect_headers
    headers = %w(errmsg.h mysqld_error.h)
    prefix = ['', 'mysql/'].find do |candidate|
      have_header("#{candidate}mysql.h")
    end
    asplode('mysql.h') unless prefix

    headers.each do |header|
      header = "#{prefix}#{header}"
      asplode(header) unless have_header(header)
    end
  end

  def detect_libraries
    libraries = %w(mysqlclient libmysql)
    library = libraries.find do |candidate|
      have_library(candidate, 'mysql_query')
    end

    asplode 'mysqlclient or libmysql' unless library
  end

  def configure_compiler
    # This is our wishlist. We use whichever flags work on the host.
    # TODO: fix statement.c and remove -Wno-declaration-after-statement
    # TODO: fix gperf mysql_enc_name_to_ruby.h and remove -Wno-missing-field-initializers
    wishlist = [
      '-Weverything',
      '-Wno-bad-function-cast', # rb_thread_call_without_gvl returns void * that we cast to VALUE
      '-Wno-conditional-uninitialized', # false positive in client.c
      '-Wno-covered-switch-default', # result.c -- enum_field_types (when fully covered, e.g. mysql 5.5)
      '-Wno-declaration-after-statement', # GET_CLIENT followed by GET_STATEMENT in statement.c
      '-Wno-disabled-macro-expansion', # rubby :(
      '-Wno-documentation-unknown-command', # rubby :(
      '-Wno-missing-field-initializers', # gperf generates bad code
      '-Wno-missing-variable-declarations', # missing symbols due to ruby native ext initialization
      '-Wno-padded', # mysql :(
      '-Wno-sign-conversion', # gperf generates bad code
      '-Wno-static-in-inline', # gperf generates bad code
      '-Wno-switch-enum', # result.c -- enum_field_types (when not fully covered, e.g. mysql 5.6+)
      '-Wno-undef', # rubinius :(
      '-Wno-used-but-marked-unused', # rubby :(
    ]

    if ENV['CI']
      wishlist += [
        '-Werror',
        '-fsanitize=address',
        '-fsanitize=cfi',
        '-fsanitize=integer',
        '-fsanitize=memory',
        '-fsanitize=thread',
        '-fsanitize=undefined',
      ]
    end

    usable_flags = wishlist.select do |flag|
      try_link('int main() {return 0;}', flag)
    end

    $CFLAGS << ' ' << usable_flags.join(' ')
  end

  def detect_by_explicit_path
    # If the user has provided a --with-mysql-dir argument, we must respect it or fail.
    inc, lib = dir_config('mysql')
    if inc && lib
      # TODO: Remove when 2.0.0 is the minimum supported version
      # Ruby versions not incorporating the mkmf fix at
      # https://bugs.ruby-lang.org/projects/ruby-trunk/repository/revisions/39717
      # do not properly search for lib directories, and must be corrected
      unless lib && lib[-3, 3] == 'lib'
        @libdir_basename = 'lib'
        inc, lib = dir_config('mysql')
      end

      error "Cannot find include dir(s) #{inc}" unless inc && inc.split(File::PATH_SEPARATOR).any? { |dir| File.directory?(dir) }
      error "Cannot find library dir(s) #{lib}" unless lib && lib.split(File::PATH_SEPARATOR).any? { |dir| File.directory?(dir) }
      warn "Using --with-mysql-dir=#{File.dirname(inc)}"
      [inc, lib]
    end
  end

  def detect_by_mysql_config
    if mysql_config_path
      warn "Using mysql_config at #{mysql_config_path}"

      ver = `#{mysql_config_path} --version`.chomp.to_f
      includes = `#{mysql_config_path} --include`.chomp
      abort unless $CHILD_STATUS.success?
      libs = `#{mysql_config_path} --libs_r`.chomp

      # MySQL 5.5 and above already have re-entrant code in libmysqlclient (no _r).
      libs = `#{mysql_config_path} --libs`.chomp if ver >= 5.5 || libs.empty?
      abort unless $CHILD_STATUS.success?

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
    'Check your installation of MySQL or Connector/C and try again.'
  end

  def mysql_config_path
    @mysql_config_path ||= with_config('mysql-config')
  end
end

# Configuration for generic Unix
class Unix < Platform
  # borrowed from mysqlplus
  # http://github.com/oldmoe/mysqlplus/blob/master/ext/extconf.rb
  DEFAULT_MYSQL_CONFIG_SEARCH_PATHS = %w(
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
    /usr/local/opt/mysql5*
  ).freeze

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
      if (libdir = rpath_dir[%r{(-L)?(/[^ ]+)}, 2])
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
    asplode('mysql client') unless mysql_client?(lib)

    [inc, lib]
  end

  def default_mysql_config_search_path
    ENV.fetch('PATH').split(File::PATH_SEPARATOR) +
      DEFAULT_MYSQL_CONFIG_SEARCH_PATHS.map { |dir| "#{dir}/bin" }
  end

  def mysql_config_glob
    "{#{default_mysql_config_search_path.join(',')}}/{mysql_config,mysql_config5,mariadb_config}"
  end

  def mysql_config_path
    super
    @mysql_config_path ||= Dir[mysql_config_glob].first
  end

  private

  def mysql_client?(lib)
    find_library('mysqlclient', 'mysql_query', lib, "#{lib}/mysql")
  end
end

# Configuration for Linux
class Linux < Unix
  protected

  def asplode_suggestion
    "You may need to 'apt-get install libmysqlclient-dev' or 'yum install mysql-devel', and try "\
    "again."
  end
end

# Configuration for Mac OS
class MacOS < Unix
  protected

  def asplode_suggestion
    "You may need to 'brew install mysql' or 'port install mysql', and try again."
  end
end

# Configuration for Windows
class Windows < Platform
  include Rake::DSL

  def configure
    super

    # Copy libmysql.dll to the local vendor directory by default
    if arg_config('--no-vendor-libmysql')
      # Fine, don't.
      warn 'Not including local libmysql.dll'
    elsif !rpath_dir
      error 'Cannot deduce path to libmysql.dll'
    else # Default: arg_config('--vendor-libmysql')
      # Vendor libmysql.dll
      vendordir = File.expand_path('../../../vendor/', __FILE__)
      directory vendordir

      vendordll = File.join(vendordir, 'libmysql.dll')
      dllfile = File.expand_path(File.join(rpath_dir, 'libmysql.dll'))
      file vendordll => [dllfile, vendordir] do
        when_writing 'copying libmysql.dll' do
          cp dllfile, vendordll
        end
      end

      Rake::Task[vendordll].invoke
    end
  end
end

# Configuration for MingW builds on Windows
class WindowsMingw < Windows
  def configure
    super

    deffile = File.expand_path('../../../support/libmysql.def', __FILE__)
    libfile = File.expand_path(File.join(rpath_dir, 'libmysql.lib'))
    file 'libmysql.a' => [deffile, libfile] do
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
