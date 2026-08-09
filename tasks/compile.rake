require "rake/extensiontask"

load File.expand_path('../../mysql2.gemspec', __FILE__) unless defined? Mysql2::GEMSPEC

Rake::ExtensionTask.new("mysql2", Mysql2::GEMSPEC) do |ext|
  # put binaries into lib/mysql2/ or lib/mysql2/x.y/
  ext.lib_dir = File.join 'lib', 'mysql2'

  # clean compiled extension
  CLEAN.include "#{ext.lib_dir}/*.#{RbConfig::CONFIG['DLEXT']}"

  if RUBY_PLATFORM =~ /mswin|mingw/
    # Any real Windows Ruby building its own extension natively -- almost
    # always RubyInstaller-based these days. This used to additionally
    # require !defined?(RubyInstaller), which was backwards: that check
    # correctly distinguishes native-vs-cross-compile *inside* extconf.rb's
    # own library-discovery logic, but here at the Rake task level it just
    # meant every real RubyInstaller Ruby (the normal case) fell through to
    # the cross-compile branch below instead, defining per-platform cross
    # tasks for a build that was never cross-compiling in the first place --
    # confirmed via CI: RubyInstaller was defined, and zero flags ever
    # reached extconf.rb's invocation.
    #
    # No explicit --with-mysql-dir needed: extconf.rb's own dir_config/
    # find_library fallback finds the MSYS2 mingw64 package (installed via
    # pacman in build-windows.yml, same as the gemspec's
    # msys2_mingw_dependencies) through gcc's own default library search
    # path for the active MSYSTEM.
  else
    ext.cross_compile = true
    ext.cross_platform = ENV['CROSS_PLATFORMS'] ? ENV['CROSS_PLATFORMS'].split(':') : ['x64-mingw32', 'x64-mingw-ucrt']
    ext.cross_config_options << {
      'x64-mingw32'    => "--with-mysql-dir=" + File.expand_path("../../vendor/#{vendor_mysql_dir('x64-mingw32')}", __FILE__),
      'x64-mingw-ucrt' => "--with-mysql-dir=" + File.expand_path("../../vendor/#{vendor_mysql_dir('x64-mingw-ucrt')}", __FILE__),
    }

    ext.cross_compiling do |spec|
      Rake::Task['lib/mysql2/mysql2.rb'].invoke
      # vendor/libmariadb.dll is invoked from extconf.rb
      Rake::Task['vendor/README'].invoke

      # only the source gem has a package dependency - the binary gem ships it's own DLL version
      spec.metadata.delete('msys2_mingw_dependencies')

      spec.files << 'lib/mysql2/mysql2.rb'
      spec.files << 'vendor/libmariadb.dll'
      spec.files << 'vendor/README'
      spec.post_install_message = <<-POST_INSTALL_MESSAGE

======================================================================================================

  You've installed the binary version of #{spec.name}.
  It was built using MariaDB Connector/C (MSYS2 package) version #{CONNECTOR_VERSION}.
  It's recommended to use the exact same version to avoid potential issues.

  At the time of building this gem, the necessary DLL files were retrieved from:
  #{vendor_mysql_url(spec.platform.to_s)}

  This gem *includes* vendor/libmariadb.dll with redistribution notice in vendor/README.

======================================================================================================

      POST_INSTALL_MESSAGE
    end
  end
end
Rake::Task[:spec].prerequisites << :compile

file 'vendor/README' do
  connector_dir = File.expand_path("../../vendor/#{vendor_mysql_dir('x64-mingw-ucrt')}", __FILE__)
  when_writing 'copying Connector/C license notice' do
    cp "#{connector_dir}/share/licenses/libmariadbclient/COPYING.LIB", 'vendor/README'
  end
end

file 'lib/mysql2/mysql2.rb' do |t|
  name = Mysql2::GEMSPEC.name
  File.open(t.name, 'wb') do |f|
    f.write <<-END_OF_RUBY
RUBY_VERSION =~ /(\\d+.\\d+)/
require "#{name}/\#{$1}/#{name}"
    END_OF_RUBY
  end
end

# DevKit task following the example of Luis Lavena's test-ruby-c-extension
task :devkit do
  begin
    require "devkit"
  rescue LoadError
    abort "Failed to activate RubyInstaller's DevKit required for compilation."
  end
end

if RUBY_PLATFORM =~ /mingw|mswin/
  Rake::Task['compile'].prerequisites.unshift 'vendor:mysql' unless defined?(RubyInstaller)
  Rake::Task['compile'].prerequisites.unshift 'devkit'
elsif Rake::Task.tasks.map(&:name).include? 'cross'
  Rake::Task['cross'].prerequisites.unshift 'vendor:mysql:cross'
end

desc "Build binary gems for Windows with rake-compiler-dock"
task 'gem:windows' do
  require 'rake_compiler_dock'
  # rake-compiler-dock >= 1.0 uses a separate, platform-tagged Docker image
  # per cross target (selected via the platform: kwarg below) rather than
  # one universal image handling every CROSS_PLATFORMS entry -- the old
  # `rake cross native gem CROSS_PLATFORMS=...` invocation doesn't define a
  # 'cross' task under this version at all. Build each platform separately
  # with the namespaced native:<platform> task instead.
  %w[x64-mingw32 x64-mingw-ucrt].each do |platform|
    RakeCompilerDock.sh(<<-EOT, platform: platform)
      sudo apt-get update
      sudo apt-get install -y zstd
    EOT
    RakeCompilerDock.sh(<<-EOT, platform: platform)
      bundle install
      rake clean
      rm -f vendor/libmariadb.dll
      rake vendor:mysql:cross
      rake native:#{platform} gem
    EOT
  end
end
