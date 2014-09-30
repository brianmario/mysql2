require 'rake/clean'
require 'rake/extensioncompiler'

CONNECTOR_VERSION = "6.1.5" #"mysql-connector-c-6.1.5-win32.zip"
CONNECTOR_PLATFORM = RUBY_PLATFORM =~ /x64/ ? "winx64" : "win32"
CONNECTOR_DIR = "mysql-connector-c-#{CONNECTOR_VERSION}-#{CONNECTOR_PLATFORM}"
CONNECTOR_ZIP = "mysql-connector-c-#{CONNECTOR_VERSION}-#{CONNECTOR_PLATFORM}.zip"

# download mysql library and headers
directory "vendor"

file "vendor/#{CONNECTOR_ZIP}" => ["vendor"] do |t|
  url = "http://cdn.mysql.com/Downloads/Connector-C/#{CONNECTOR_ZIP}"
  when_writing "downloading #{t.name}" do
    cd File.dirname(t.name) do
      sh "curl -C - -O #{url} || wget -c #{url}"
    end
  end
end

file "vendor/#{CONNECTOR_DIR}/include/mysql.h" => ["vendor/#{CONNECTOR_ZIP}"] do |t|
  full_file = File.expand_path(t.prerequisites.last)
  when_writing "creating #{t.name}" do
    cd "vendor" do
      sh "unzip #{full_file} #{CONNECTOR_DIR}/bin/** #{CONNECTOR_DIR}/include/** #{CONNECTOR_DIR}/lib/**"
    end
    # update file timestamp to avoid Rake perform this extraction again.
    touch t.name
  end
end

# clobber expanded packages
CLOBBER.include("vendor/#{CONNECTOR_DIR}")

# vendor:mysql
task 'vendor:mysql' => "vendor/#{CONNECTOR_DIR}/include/mysql.h"
