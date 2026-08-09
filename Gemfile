source 'https://rubygems.org'

gemspec

if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.2")
  gem 'rake', '~> 13.0'
else
  gem 'rake', '< 13'
end
gem 'rake-compiler', '~> 1.2.0'

# For local debugging, irb is Gemified since Ruby 2.6
gem 'irb', require: false

group :test do
  unless RUBY_PLATFORM =~ /mswin|mingw/
    if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('4.0')
      # Ruby 4.0 removed Data_Wrap_Struct, breaking eventmachine 1.2.7's
      # fastfilereader ext; use git master until a fix is released.
      gem 'eventmachine', github: 'eventmachine/eventmachine'
    else
      gem 'eventmachine'
    end
  end
  gem 'rspec', '~> 3.2'

  gem 'rubocop'

  gem 'clocale'
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
  gem 'rake-compiler-dock', '~> 1.12'
end

# On MRI Ruby >= 3.0, rubysl-rake causes the conflict on GitHub Actions.
# platforms :rbx do
#   gem 'rubysl-bigdecimal'
#   gem 'rubysl-drb'
#   gem 'rubysl-rake'
# end
