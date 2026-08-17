$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'mysql2'
require 'trilogy'

def run_escape_benchmarks(str)
  Benchmark.ips do |x|
    mysql2 = Mysql2::Client.new(host: "localhost", username: "root")
    x.report "Mysql2 #{str.inspect}" do
      mysql2.escape str
    end

    trilogy = Trilogy.new(host: "localhost", username: "root")
    x.report "Trilogy #{str.inspect}" do
      trilogy.escape str
    end

    x.compare!
  end
end

run_escape_benchmarks "abc'def\"ghi\0jkl%mno"
run_escape_benchmarks "clean string"
