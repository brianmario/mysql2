gem 'rake-compiler', '~> 0.7.1'
require "rake/extensiontask"

MYSQL_VERSION = "5.1.49"
MYSQL_MIRROR  = ENV['MYSQL_MIRROR'] || "http://mysql.localhost.net.ar"

Rake::ExtensionTask.new("mysql2", JEWELER.gemspec) do |ext|
  # reference where the vendored MySQL got extracted
  mysql_lib = File.expand_path(File.join(File.dirname(__FILE__), '..', 'vendor', "mysql-#{MYSQL_VERSION}-win32"))

  # automatically add build options to avoid need of manual input
  if RUBY_PLATFORM =~ /mswin|mingw/ then
    ext.config_options << "--with-mysql-include=#{mysql_lib}/include"
    ext.config_options << "--with-mysql-lib=#{mysql_lib}/lib/opt"
  end

  ext.lib_dir = File.join 'lib', 'mysql2'
end
Rake::Task[:spec].prerequisites << :compile
