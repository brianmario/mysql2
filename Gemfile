source 'https://rubygems.org'

gemspec

# benchmarks
group :benchmarks do
  gem 'activerecord', '>= 3.0'
  gem 'mysql'
  gem 'do_mysql'
  gem 'sequel'
  gem 'faker'
end

group :development do
  gem 'pry'
  gem 'eventmachine' unless RUBY_PLATFORM =~ /mswin|mingw/
  gem 'rake-compiler-dock', '~> 0.4.2'
end

platforms :rbx do
  gem 'rubysl-rake'
  gem 'rubysl-drb'
  gem 'rubysl-bigdecimal'
end
