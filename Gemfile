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

  # Downgrade psych because old RuboCop can't use new Psych
  gem 'psych', '< 4.0.0'
  # https://github.com/bbatsov/rubocop/pull/4789
  gem 'rubocop', '~> 0.50.0'
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
