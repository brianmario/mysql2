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
has_rubocop = if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'ruby' && defined?(Encoding)
  begin
    require 'rubocop/rake_task'
    RuboCop::RakeTask.new
    task :default => [:spec, :rubocop]
  rescue LoadError # rubocop:disable Lint/HandleExceptions
  end
end

unless has_rubocop
  warn 'RuboCop is not available'
  task :default => :spec
end
