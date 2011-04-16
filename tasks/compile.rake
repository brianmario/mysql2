require "rake/extensiontask"

CONNECTOR_VERSION = "6.0.2" #"mysql-connector-c-noinstall-6.0.2-win32.zip"
CONNECTOR_MIRROR = ENV['CONNECTOR_MIRROR'] || ENV['MYSQL_MIRROR'] || "http://mysql.he.net/"

def gemspec
  @clean_gemspec ||= eval(File.read(File.expand_path('../../mysql2.gemspec', __FILE__)))
end

Rake::ExtensionTask.new("mysql2", gemspec) do |ext|
  # reference where the vendored MySQL got extracted
  connector_lib = File.expand_path(File.join(File.dirname(__FILE__), '..', 'vendor', "mysql-connector-c-noinstall-#{CONNECTOR_VERSION}-win32"))

  # DRY options feed into compile or cross-compile process
  windows_options = [
    "--with-mysql-include=#{connector_lib}/include",
    "--with-mysql-lib=#{connector_lib}/lib"
  ]

  # automatically add build options to avoid need of manual input
  if RUBY_PLATFORM =~ /mswin|mingw/ then
    ext.config_options = windows_options
  else
    ext.cross_compile = true
    ext.cross_platform = ['x86-mingw32', 'x86-mswin32-60']
    ext.cross_config_options = windows_options

    # inject 1.8/1.9 pure-ruby entry point when cross compiling only
    ext.cross_compiling do |spec|
      spec.files << 'lib/mysql2/mysql2.rb'
      spec.post_install_message = <<-POST_INSTALL_MESSAGE

======================================================================================================

  You've installed the binary version of #{spec.name}.
  It was built using MySQL Connector/C version #{CONNECTOR_VERSION}.
  It's recommended to use the exact same version to avoid potential issues.

  At the time of building this gem, the necessary DLL files where available
  in the following download:

  http://dev.mysql.com/get/Downloads/Connector-C/mysql-connector-c-noinstall-#{CONNECTOR_VERSION}-win32.zip/from/pick

  And put lib\\libmysql.dll file in your Ruby bin directory, for example C:\\Ruby\\bin

======================================================================================================

      POST_INSTALL_MESSAGE
    end
  end

  ext.lib_dir = File.join 'lib', 'mysql2'

  # clean compiled extension
  CLEAN.include "#{ext.lib_dir}/*.#{RbConfig::CONFIG['DLEXT']}"
end
Rake::Task[:spec].prerequisites << :compile

file 'lib/mysql2/mysql2.rb' do |t|
  name = gemspec.name
  File.open(t.name, 'wb') do |f|
    f.write <<-eoruby
RUBY_VERSION =~ /(\\d+.\\d+)/
require "#{name}/\#{$1}/#{name}"
    eoruby
  end
end

if Rake::Task.task_defined?(:cross)
  Rake::Task[:cross].prerequisites << "lib/mysql2/mysql2.rb"
end
