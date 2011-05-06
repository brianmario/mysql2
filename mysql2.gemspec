require File.expand_path('../lib/mysql2/version', __FILE__)

Gem::Specification.new do |s|
  s.name = %q{mysql2}
  s.version = Mysql2::VERSION
  s.authors = ["Brian Lopez"]
  s.date = Time.now.utc.strftime("%Y-%m-%d")
  s.email = %q{seniorlopez@gmail.com}
  s.extensions = ["ext/mysql2/extconf.rb"]
  s.files = `git ls-files`.split("\n")
  s.homepage = %q{http://github.com/brianmario/mysql2}
  s.rdoc_options = ["--charset=UTF-8"]
  s.require_paths = ["lib", "ext"]
  s.rubygems_version = %q{1.4.2}
  s.summary = %q{A simple, fast Mysql library for Ruby, binding to libmysql}
  s.test_files = `git ls-files spec examples`.split("\n")

  # tests
  s.add_development_dependency 'eventmachine'
  s.add_development_dependency 'rake-compiler', "~> 0.7.7"
  s.add_development_dependency 'rspec'
  # benchmarks
  s.add_development_dependency 'activerecord'
  s.add_development_dependency 'mysql'
  s.add_development_dependency 'do_mysql'
  s.add_development_dependency 'sequel'
  s.add_development_dependency 'faker'
end

