$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'mysql'
require 'mysql2'
require 'do_mysql'

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

  mysql = Mysql.new("localhost", "root")
  mysql.query "USE #{database}"
  x.report "Mysql" do
    mysql_result = mysql.query sql
    mysql_result.each_hash { |res| puts res.inspect if debug }
  end

  do_mysql = DataObjects::Connection.new("mysql://localhost/#{database}")
  command = DataObjects::Mysql::Command.new do_mysql, sql
  x.report "do_mysql" do
    do_result = command.execute_reader
    do_result.each { |res| puts res.inspect if debug }
  end

  x.compare!
end
