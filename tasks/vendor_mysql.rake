require 'rake/clean'
require 'rake/extensioncompiler'

CONNECTOR_VERSION = "6.1.6" # NOTE: Track the upstream version from time to time

def vendor_mysql_platform(platform = nil)
  platform ||= RUBY_PLATFORM
  platform =~ /x64/ ? "winx64" : "win32"
end

def vendor_mysql_dir(*args)
  "mysql-connector-c-#{CONNECTOR_VERSION}-#{vendor_mysql_platform(*args)}"
end

def vendor_mysql_zip(*args)
  "#{vendor_mysql_dir(*args)}.zip"
end

def vendor_mysql_url(*args)
  "http://cdn.mysql.com/Downloads/Connector-C/#{vendor_mysql_zip(*args)}"
end

# vendor:mysql
task "vendor:mysql:cross" do
  # When cross-compiling, grab both 32 and 64 bit connectors
  Rake::Task['vendor:mysql'].invoke('x86')
  Rake::Task['vendor:mysql'].invoke('x64')
end

task "vendor:mysql", [:platform] do |_t, args|
  puts "vendor:mysql for #{vendor_mysql_dir(args[:platform])}"

  # download mysql library and headers
  directory "vendor"

  file "vendor/#{vendor_mysql_zip(args[:platform])}" => ["vendor"] do |t|
    url = vendor_mysql_url(args[:platform])
    when_writing "downloading #{t.name}" do
      cd "vendor" do
        sh "curl", "-C", "-", "-O", url do |ok|
          sh "wget", "-c", url unless ok
        end
      end
    end
  end

  file "vendor/#{vendor_mysql_dir(args[:platform])}/include/mysql.h" => ["vendor/#{vendor_mysql_zip(args[:platform])}"] do |t|
    full_file = File.expand_path(t.prerequisites.last)
    when_writing "creating #{t.name}" do
      cd "vendor" do
        sh "unzip", "-uq", full_file,
           "#{vendor_mysql_dir(args[:platform])}/bin/\\*\\*",
           "#{vendor_mysql_dir(args[:platform])}/include/\\*\\*",
           "#{vendor_mysql_dir(args[:platform])}/lib/\\*\\*",
           "#{vendor_mysql_dir(args[:platform])}/README" # contains the license info
      end
      # update file timestamp to avoid Rake performing this extraction again.
      touch t.name
    end
  end

  # clobber expanded packages
  CLOBBER.include("vendor/#{vendor_mysql_dir(args[:platform])}")

  Rake::Task["vendor/#{vendor_mysql_dir(args[:platform])}/include/mysql.h"].invoke
  Rake::Task["vendor:mysql"].reenable # allow task to be invoked again (with another platform)
end
