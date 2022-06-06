source 'https://rubygems.org'

gemspec

if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.2")
  gem 'rake', '~> 13.0.1'
else
  gem 'rake', '< 13'
end
gem 'rake-compiler', '~> 1.1.0'

# For local debugging, irb is Gemified since Ruby 2.6
gem 'irb', require: false

group :test do
  gem 'eventmachine' unless RUBY_PLATFORM =~ /mswin|mingw/
  gem 'rspec', '~> 3.2'

  # https://github.com/bbatsov/rubocop/pull/4789
  gem 'rubocop', '~> 1.30', '>= 1.30.1' if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.6')
end

group :benchmarks, optional: true do
  gem 'activerecord', '>= 3.0'
  gem 'benchmark-ips'
  gem 'do_mysql'
  gem 'faker'
  # The installation of the mysql latest version 2.9.1 fails on Ruby >= 2.4.
  gem 'mysql' if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.4')
  gem 'sequel'
end

group :development do
  gem 'pry'
  gem 'rake-compiler-dock', '~> 0.7.0'
end

# On MRI Ruby >= 3.0, rubysl-rake causes the conflict on GitHub Actions.
# platforms :rbx do
#   gem 'rubysl-bigdecimal'
#   gem 'rubysl-drb'
#   gem 'rubysl-rake'
# end
