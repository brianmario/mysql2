source 'https://rubygems.org'

gemspec

# benchmarks
group :benchmarks do
  gem 'activerecord', '>= 3.0'
  gem 'benchmark-ips'
  gem 'do_mysql'
  gem 'faker'
  gem 'mysql'
  gem 'sequel'
end

group :development do
  gem 'eventmachine' unless RUBY_PLATFORM =~ /mswin|mingw/
  gem 'pry'
end

platforms :rbx do
  gem 'rubysl-bigdecimal'
  gem 'rubysl-drb'
  gem 'rubysl-rake'
end
