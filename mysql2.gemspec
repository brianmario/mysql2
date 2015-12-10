Mysql2::GEMSPEC = Gem::Specification.new do |s|
  s.name = 'mysql2'
  s.version = '0.4.2'
  s.authors = ['Brian Lopez', 'Aaron Stone']
  s.license = "MIT"
  s.email = ['seniorlopez@gmail.com', 'aaron@serendipity.cx']
  s.extensions = ["ext/mysql2/extconf.rb"]
  s.homepage = 'http://github.com/brianmario/mysql2'
  s.rdoc_options = ["--charset=UTF-8"]
  s.summary = 'A simple, fast Mysql library for Ruby, binding to libmysql'

  s.files = `git ls-files README.md CHANGELOG.md LICENSE ext lib support`.split
  s.test_files = `git ls-files spec examples`.split
end
