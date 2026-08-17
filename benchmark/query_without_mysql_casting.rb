$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'mysql2'
require 'trilogy'

database = 'test'
sql = "SELECT * FROM mysql2_test LIMIT 100"

debug = ENV['DEBUG']

Benchmark.ips do |x|
  mysql2 = Mysql2::Client.new(host: "localhost", username: "root")
  mysql2.query "USE #{database}"
  x.report "Mysql2 (cast: true)" do
    mysql2_result = mysql2.query sql, symbolize_keys: true, cast: true
    mysql2_result.each { |res| puts res.inspect if debug }
  end

  x.report "Mysql2 (cast: false)" do
    mysql2_result = mysql2.query sql, symbolize_keys: true, cast: false
    mysql2_result.each { |res| puts res.inspect if debug }
  end

  trilogy = Trilogy.new(host: "localhost", username: "root", database: database)
  cast_flags = trilogy.query_flags | Trilogy::QUERY_FLAGS_CAST | Trilogy::QUERY_FLAGS_CAST_BOOLEANS
  no_cast_flags = trilogy.query_flags & ~Trilogy::QUERY_FLAGS_CAST & ~Trilogy::QUERY_FLAGS_CAST_BOOLEANS

  x.report "Trilogy (cast: true)" do
    trilogy_result = trilogy.query_with_flags sql, cast_flags
    trilogy_result.each_hash { |res| puts res.inspect if debug }
  end

  x.report "Trilogy (cast: false)" do
    trilogy_result = trilogy.query_with_flags sql, no_cast_flags
    trilogy_result.each_hash { |res| puts res.inspect if debug }
  end

  x.compare!
end
