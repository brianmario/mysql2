$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'mysql'
require 'mysql2'
require 'do_mysql'

def run_escape_benchmarks(str)
  Benchmark.ips do |x|
    mysql = Mysql.new("localhost", "root")

    x.report "Mysql #{str.inspect}" do
      mysql.quote str
    end

    mysql2 = Mysql2::Client.new(host: "localhost", username: "root")
    x.report "Mysql2 #{str.inspect}" do
      mysql2.escape str
    end

    do_mysql = DataObjects::Connection.new("mysql://localhost/test")
    x.report "do_mysql #{str.inspect}" do
      do_mysql.quote_string str
    end

    x.compare!
  end
end

run_escape_benchmarks "abc'def\"ghi\0jkl%mno"
run_escape_benchmarks "clean string"
