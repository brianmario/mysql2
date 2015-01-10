require "rake/extensiontask"

def gemspec
  @clean_gemspec ||= eval(File.read(File.expand_path('../../mysql2.gemspec', __FILE__)))
end

Rake::ExtensionTask.new("mysql2", gemspec) do |ext|
  # put binaries into lib/mysql2/ or lib/mysql2/x.y/
  ext.lib_dir = File.join 'lib', 'mysql2'

  # clean compiled extension
  CLEAN.include "#{ext.lib_dir}/*.#{RbConfig::CONFIG['DLEXT']}"

  if RUBY_PLATFORM =~ /mswin|mingw/ then
    Rake::Task['vendor:mysql'].invoke
    # Expand the path because the build dir is 3-4 levels deep in tmp/platform/version/
    connector_dir = File.expand_path("../../vendor/#{vendor_mysql_dir}", __FILE__)
    ext.config_options = [ "--with-mysql-dir=#{connector_dir}" ]
  else
    Rake::Task['vendor:mysql'].invoke('x86')
    Rake::Task['vendor:mysql'].invoke('x64')
    ext.cross_compile = true
    ext.cross_platform = ['x86-mingw32', 'x86-mswin32-60', 'x64-mingw32']
    ext.cross_config_options = {
      'x86-mingw32'    => [ "--with-mysql-dir=" + File.expand_path("../../vendor/#{vendor_mysql_dir('x86')}", __FILE__) ],
      'x86-mswin32-60' => [ "--with-mysql-dir=" + File.expand_path("../../vendor/#{vendor_mysql_dir('x86')}", __FILE__) ],
      'x64-mingw32'    => [ "--with-mysql-dir=" + File.expand_path("../../vendor/#{vendor_mysql_dir('x64')}", __FILE__) ],
    }

    ext.cross_compiling do |spec|
      Rake::Task['lib/mysql2/mysql2.rb'].invoke
      spec.files << 'lib/mysql2/mysql2.rb'
      spec.files << 'vendor/libmysql.dll'
      spec.post_install_message = <<-POST_INSTALL_MESSAGE

======================================================================================================

  You've installed the binary version of #{spec.name}.
  It was built using MySQL Connector/C version #{CONNECTOR_VERSION}.
  It's recommended to use the exact same version to avoid potential issues.

  At the time of building this gem, the necessary DLL files were available
  in the following download:

  #{vendor_mysql_url(spec.platform)}

  And put lib\\libmysql.dll file in your Ruby bin directory, for example C:\\Ruby\\bin

======================================================================================================

      POST_INSTALL_MESSAGE
    end
  end
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

# DevKit task following the example of Luis Lavena's test-ruby-c-extension
task :devkit do
  begin
    require "devkit"
  rescue LoadError => e
    abort "Failed to activate RubyInstaller's DevKit required for compilation."
  end
end

if RUBY_PLATFORM =~ /mingw|mswin/ then
  Rake::Task['compile'].prerequisites.unshift 'vendor:mysql'
  Rake::Task['compile'].prerequisites.unshift 'devkit'
end
