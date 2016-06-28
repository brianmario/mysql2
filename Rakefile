# encoding: UTF-8
require 'rake'

# Load custom tasks (careful attention to define tasks before prerequisites)
load 'tasks/vendor_mysql.rake'
load 'tasks/rspec.rake'
load 'tasks/compile.rake'
load 'tasks/generate.rake'
load 'tasks/benchmarks.rake'

# TODO: remove engine check when rubinius stops crashing on RuboCop
# TODO: remove defined?(Encoding) when we end support for < 1.9.3
if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'ruby' && defined?(Encoding)
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
  task :default => [:spec, :rubocop]
else
  warn 'RuboCop is not available'
  task :default => :spec
end
