# encoding: UTF-8
# begin
#   require 'jeweler'
#   Jeweler::Tasks.new do |gem|
#     gem.name = "yajl-ruby"
#     gem.summary = "Ruby C bindings to the excellent Yajl JSON stream-based parser library."
#     gem.email = "seniorlopez@gmail.com"
#     gem.homepage = "http://github.com/brianmario/yajl-ruby"
#     gem.authors = ["Brian Lopez", "Lloyd Hilaiel"]
#     gem.require_paths = ["lib", "ext"]
#     gem.extra_rdoc_files = `git ls-files *.rdoc`.split("\n")
#     gem.files = `git ls-files`.split("\n")
#     gem.extensions = ["ext/extconf.rb"]
#     gem.files.include %w(lib/jeweler/templates/.document lib/jeweler/templates/.gitignore)
#     gem.rubyforge_project = "yajl-ruby"
#   end
# rescue LoadError
#   puts "Jeweler, or one of its dependencies, is not available. Install it with: sudo gem install jeweler -s http://gems.github.com"
# end

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
end