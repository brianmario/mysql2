begin
  require 'rspec'
  require 'rspec/core/rake_task'

  desc "Run all examples with RCov"
  RSpec::Core::RakeTask.new('spec:rcov') do |t|
    t.rcov = true
  end
  RSpec::Core::RakeTask.new('spec') do |t|
    t.verbose = true
  end

  task :default => :spec
rescue LoadError
  puts "rspec, or one of its dependencies, is not available. Install it with: sudo gem install rspec"
end

file 'spec/configuration.yml' => 'spec/configuration.yml.example' do |task|
  CLEAN.exclude task.name
  cp task.prerequisites.first, task.name
  sh "sed -i 's/LOCALUSERNAME/#{ENV['USER']}/' #{task.name}"
end

task :spec => :'spec/configuration.yml'
