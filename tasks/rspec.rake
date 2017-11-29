begin
  require 'rspec'
  require 'rspec/core/rake_task'

  desc " Run all examples with Valgrind"
  namespace :spec do
    task :valgrind do
      VALGRIND_OPTS = %w[
        --num-callers=50
        --error-limit=no
        --partial-loads-ok=yes
        --undef-value-errors=no
        --trace-children=yes
      ].freeze
      cmdline = "valgrind #{VALGRIND_OPTS.join(' ')} bundle exec rake spec"
      puts cmdline
      system cmdline
    end
  end

  desc "Run all examples with RCov"
  RSpec::Core::RakeTask.new('spec:rcov') do |t|
    t.rcov = true
  end

  RSpec::Core::RakeTask.new('spec') do |t|
    t.verbose = true
  end
rescue LoadError
  puts "rspec, or one of its dependencies, is not available. Install it with: sudo gem install rspec"
end

file 'spec/configuration.yml' => 'spec/configuration.yml.example' do |task|
  CLEAN.exclude task.name
  src_path = File.expand_path("../../#{task.prerequisites.first}", __FILE__)
  dst_path = File.expand_path("../../#{task.name}", __FILE__)

  File.open(dst_path, 'w') do |dst_file|
    File.open(src_path).each_line do |line|
      dst_file.write line.gsub(/LOCALUSERNAME/, ENV['USER'])
    end
  end
end

file 'spec/my.cnf' => 'spec/my.cnf.example' do |task|
  CLEAN.exclude task.name
  src_path = File.expand_path("../../#{task.prerequisites.first}", __FILE__)
  dst_path = File.expand_path("../../#{task.name}", __FILE__)

  File.open(dst_path, 'w') do |dst_file|
    File.open(src_path).each_line do |line|
      dst_file.write line.gsub(/LOCALUSERNAME/, ENV['USER'])
    end
  end
end

Rake::Task[:spec].prerequisites << :'spec/configuration.yml'
Rake::Task[:spec].prerequisites << :'spec/my.cnf'
