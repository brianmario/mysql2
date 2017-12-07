require File.expand_path('../lib/mysql2/version', __FILE__)

Mysql2::GEMSPEC = Gem::Specification.new do |s|
  s.name = 'mysql2'
  s.version = Mysql2::VERSION
  s.authors = ['Brian Lopez', 'Aaron Stone']
  s.license = "MIT"
  s.email = ['seniorlopez@gmail.com', 'aaron@serendipity.cx']
  s.extensions = ["ext/mysql2/extconf.rb"]
  s.homepage = 'https://github.com/brianmario/mysql2'
  s.rdoc_options = ["--charset=UTF-8"]
  s.summary = 'A simple, fast Mysql library for Ruby, binding to libmysql'
  s.required_ruby_version = '>= 2.0.0'

  s.files = `git ls-files README.md CHANGELOG.md LICENSE ext lib support`.split
  s.test_files = `git ls-files spec examples`.split

  s.metadata['msys2_mingw_dependencies'] = 'libmariadbclient'
end
