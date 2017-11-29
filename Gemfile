source 'https://rubygems.org'

gemspec

gem 'rake', '~> 10.4.2'
gem 'rake-compiler', '~> 1.0'

group :test do
  gem 'eventmachine' unless RUBY_PLATFORM =~ /mswin|mingw/
  gem 'rspec', '~> 3.2'
  # https://github.com/bbatsov/rubocop/pull/4789
  gem 'rubocop', '~> 0.50.0'
end

group :benchmarks do
  gem 'activerecord', '>= 3.0'
  gem 'benchmark-ips'
  gem 'do_mysql'
  gem 'faker'
  gem 'mysql'
  gem 'sequel'
end

group :development do
  gem 'pry'
  gem 'rake-compiler-dock', '~> 0.6.0'
end

platforms :rbx do
  gem 'rubysl-bigdecimal'
  gem 'rubysl-drb'
  gem 'rubysl-rake'
end
