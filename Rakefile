# encoding: UTF-8
begin
  require 'jeweler'
  JEWELER = Jeweler::Tasks.new do |gem|
    gem.name = "mysql2"
    gem.summary = "A simple, fast Mysql library for Ruby, binding to libmysql"
    gem.email = "seniorlopez@gmail.com"
    gem.homepage = "http://github.com/brianmario/mysql2"
    gem.authors = ["Brian Lopez"]
    gem.require_paths = ["lib", "ext"]
    gem.extra_rdoc_files = `git ls-files *.rdoc`.split("\n")
    gem.files = `git ls-files`.split("\n")
    gem.extensions = ["ext/mysql2/extconf.rb"]
    gem.files.include %w(lib/jeweler/templates/.document lib/jeweler/templates/.gitignore)
    # gem.rubyforge_project = "mysql2"
  end
rescue LoadError
  puts "Jeweler, or one of its dependencies, is not available. Install it with: sudo gem install jeweler -s http://gems.github.com"
end

require 'rake'
require 'spec/rake/spectask'

desc "Run all examples with RCov"
Spec::Rake::SpecTask.new('spec:rcov') do |t|
  t.spec_files = FileList['spec/']
  t.rcov = true
  t.rcov_opts = lambda do
    IO.readlines("spec/rcov.opts").map {|l| l.chomp.split " "}.flatten
  end
end
Spec::Rake::SpecTask.new('spec') do |t|
  t.spec_files = FileList['spec/']
  t.spec_opts << '--options' << 'spec/spec.opts'
  t.verbose = true
  t.warning = true
end

task :default => :spec

# Load custom tasks
Dir['tasks/*.rake'].sort.each { |f| load f }
