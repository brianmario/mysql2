require 'rake'

# Load custom tasks (careful attention to define tasks before prerequisites)
load 'tasks/vendor_mysql.rake'
load 'tasks/rspec.rake'
load 'tasks/compile.rake'
load 'tasks/generate.rake'
load 'tasks/benchmarks.rake'

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
  task default: %i[spec rubocop]
rescue LoadError
  warn 'RuboCop is not available'
  task default: :spec
end
