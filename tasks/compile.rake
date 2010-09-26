gem 'rake-compiler', '~> 0.7.1'
require "rake/extensiontask"

MYSQL_VERSION = "5.1.51"
MYSQL_MIRROR  = ENV['MYSQL_MIRROR'] || "http://mysql.he.net/"

def gemspec
  @clean_gemspec ||= eval(File.read(File.expand_path('../../mysql2.gemspec', __FILE__)))
end

Rake::ExtensionTask.new("mysql2", gemspec) do |ext|
  # reference where the vendored MySQL got extracted
  mysql_lib = File.expand_path(File.join(File.dirname(__FILE__), '..', 'vendor', "mysql-#{MYSQL_VERSION}-win32"))

  # automatically add build options to avoid need of manual input
  if RUBY_PLATFORM =~ /mswin|mingw/ then
    ext.config_options << "--with-mysql-include=#{mysql_lib}/include"
    ext.config_options << "--with-mysql-lib=#{mysql_lib}/lib/opt"
  else
    ext.cross_compile = true
    ext.cross_platform = ['x86-mingw32', 'x86-mswin32-60']
    ext.cross_config_options << "--with-mysql-include=#{mysql_lib}/include"
    ext.cross_config_options << "--with-mysql-lib=#{mysql_lib}/lib/opt"
  end

  ext.lib_dir = File.join 'lib', 'mysql2'

  # clean compiled extension
  CLEAN.include "#{ext.lib_dir}/*.#{RbConfig::CONFIG['DLEXT']}"
end
Rake::Task[:spec].prerequisites << :compile

namespace :cross do
  task :file_list do
    gemspec.extensions = []
    gemspec.files += Dir["lib/#{gemspec.name}/#{gemspec.name}.rb"]
    gemspec.files += Dir["lib/#{gemspec.name}/1.{8,9}/#{gemspec.name}.so"]
    # gemspec.files += Dir["ext/mysql2/*.dll"]
  end
end

file 'lib/mysql2/mysql2.rb' do
  name = gemspec.name
  File.open("lib/#{name}/#{name}.rb", 'wb') do |f|
    f.write <<-eoruby
require "#{name}/\#{RUBY_VERSION.sub(/\\.\\d+$/, '')}/#{name}"
    eoruby
  end
end

if Rake::Task.task_defined?(:cross)
  Rake::Task[:cross].prerequisites << "lib/mysql2/mysql2.rb"
  Rake::Task[:cross].prerequisites << "cross:file_list"
end
