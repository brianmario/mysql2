BENCHMARKS = Dir["#{File.dirname(__FILE__)}/../benchmark/*.rb"].map do |path|
  File.basename(path, '.rb')
end

namespace :bench do
  BENCHMARKS.each do |feature|
      desc "Run #{feature} benchmarks"
      task(feature){ ruby "benchmark/#{feature}.rb" }
  end
  task :all do
    BENCHMARKS.each do |feature|
      ruby "benchmark/#{feature}.rb"
    end
  end
end