source 'https://rubygems.org'

gemspec

gem 'rake', if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.2")
              '~> 13.0.1'
            else
              '< 13'
            end
gem 'rake-compiler', '~> 1.1.0'

# For local debugging, irb is Gemified since Ruby 2.6
gem 'irb', require: false

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
  gem 'rake-compiler-dock', '~> 0.7.0'
end

platforms :rbx do
  gem 'rubysl-bigdecimal'
  gem 'rubysl-drb'
  gem 'rubysl-rake'
end
