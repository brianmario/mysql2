require 'rake/clean'
require 'rake/extensioncompiler'

# MariaDB Connector/C no longer publishes prebuilt Windows binaries through
# any public, unauthenticated URL (only source archives via
# downloads.mariadb.org's REST API; the prebuilt .msi installers live on
# dlm.mariadb.com, which requires a paid Enterprise customer token). Vendor
# the same MSYS2 mingw-w64 package instead -- prebuilt specifically for the
# mingw-w64/UCRT64 toolchains rake-compiler-dock cross-compiles against,
# with stable public URLs, and already what a native Windows build pulls in
# via pacman (see build-windows.yml / the gemspec's msys2_mingw_dependencies).
#
# NOTE: Track the upstream package version from time to time.
CONNECTOR_VERSION = "3.4.9-1".freeze

MSYS2_MIRROR = "https://mirror.msys2.org".freeze

# Maps a rake-compiler-dock cross platform to the MSYS2 tree that provides a
# prebuilt mingw-w64 MariaDB Connector/C for it. Both are 64-bit; they differ
# in C runtime (traditional msvcrt vs. UCRT, matching Ruby's own platform
# split at RubyInstaller's UCRT migration around Ruby 3.1).
MSYS2_TREES = {
  'x64-mingw32'    => { subtree: 'mingw64', pkg_prefix: 'mingw-w64-x86_64', dir: 'mingw64' },
  'x64-mingw-ucrt' => { subtree: 'ucrt64', pkg_prefix: 'mingw-w64-ucrt-x86_64', dir: 'ucrt64' },
}.freeze

def vendor_mysql_tree(platform)
  MSYS2_TREES.fetch(platform) do
    raise "No MSYS2 tree known for cross platform #{platform.inspect} -- add one to MSYS2_TREES in tasks/vendor_mysql.rake"
  end
end

# The directory prefix inside the extracted package, and what compile.rake
# passes as --with-mysql-dir.
def vendor_mysql_dir(platform)
  vendor_mysql_tree(platform)[:dir]
end

def vendor_mysql_pkg(platform)
  "#{vendor_mysql_tree(platform)[:pkg_prefix]}-libmariadbclient-#{CONNECTOR_VERSION}-any.pkg.tar.zst"
end

def vendor_mysql_url(platform)
  "#{MSYS2_MIRROR}/mingw/#{vendor_mysql_tree(platform)[:subtree]}/#{vendor_mysql_pkg(platform)}"
end

# vendor:mysql
task "vendor:mysql:cross" do
  Rake::Task['vendor:mysql'].invoke('x64-mingw32')
  Rake::Task['vendor:mysql'].invoke('x64-mingw-ucrt')
end

task "vendor:mysql", [:platform] do |_t, args|
  platform = args[:platform]
  puts "vendor:mysql for #{platform} (MSYS2 #{vendor_mysql_tree(platform)[:subtree]})"

  # download MariaDB Connector/C library and headers
  directory "vendor"

  pkg_file = "vendor/#{vendor_mysql_pkg(platform)}"
  file pkg_file => ["vendor"] do |t|
    url = vendor_mysql_url(platform)
    when_writing "downloading #{t.name}" do
      cd "vendor" do
        sh "curl", "-fL", "-o", File.basename(t.name), url
      end
    end
  end

  file "vendor/#{vendor_mysql_dir(platform)}/include/mysql/mysql.h" => [pkg_file] do |t|
    full_file = File.expand_path(t.prerequisites.last)
    when_writing "creating #{t.name}" do
      cd "vendor" do
        # MSYS2 packages are zstd-compressed tarballs; extract only the
        # payload tree (bin/include/lib/share -- skips the pacman control
        # files like .PKGINFO/.BUILDINFO/.MTREE at the archive root).
        sh "sh", "-c", "zstd -dc #{full_file.inspect} | tar -x #{vendor_mysql_dir(platform)}/bin #{vendor_mysql_dir(platform)}/include #{vendor_mysql_dir(platform)}/lib #{vendor_mysql_dir(platform)}/share/licenses"
      end
      # update file timestamp to avoid Rake performing this extraction again.
      touch t.name
    end
  end

  # clobber expanded packages
  CLOBBER.include("vendor/#{vendor_mysql_dir(platform)}")

  Rake::Task["vendor/#{vendor_mysql_dir(platform)}/include/mysql/mysql.h"].invoke
  Rake::Task["vendor:mysql"].reenable # allow task to be invoked again (with another platform)
end
