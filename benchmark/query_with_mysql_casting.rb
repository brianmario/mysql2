$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'mysql'
require 'mysql2'
require 'do_mysql'

database = 'test'
sql = "SELECT * FROM mysql2_test LIMIT 100"

class Mysql
  include Enumerable
end

def mysql_cast(type, value)
  case type
  when Mysql::Field::TYPE_NULL
    nil
  when Mysql::Field::TYPE_TINY, Mysql::Field::TYPE_SHORT, Mysql::Field::TYPE_LONG,
      Mysql::Field::TYPE_INT24, Mysql::Field::TYPE_LONGLONG, Mysql::Field::TYPE_YEAR
    value.to_i
  when Mysql::Field::TYPE_DECIMAL, Mysql::Field::TYPE_NEWDECIMAL
    BigDecimal(value)
  when Mysql::Field::TYPE_DOUBLE, Mysql::Field::TYPE_FLOAT
    value.to_f
  when Mysql::Field::TYPE_DATE
    Date.parse(value)
  when Mysql::Field::TYPE_TIME, Mysql::Field::TYPE_DATETIME, Mysql::Field::TYPE_TIMESTAMP
    Time.parse(value)
  when Mysql::Field::TYPE_BLOB, Mysql::Field::TYPE_BIT, Mysql::Field::TYPE_STRING,
      Mysql::Field::TYPE_VAR_STRING, Mysql::Field::TYPE_CHAR, Mysql::Field::TYPE_SET,
      Mysql::Field::TYPE_ENUM
    value
  else
    value
  end
end

debug = ENV['DEBUG']

Benchmark.ips do |x|
  mysql2 = Mysql2::Client.new(host: "localhost", username: "root")
  mysql2.query "USE #{database}"
  x.report "Mysql2" do
    mysql2_result = mysql2.query sql, symbolize_keys: true
    mysql2_result.each { |res| puts res.inspect if debug }
  end

  mysql = Mysql.new("localhost", "root")
  mysql.query "USE #{database}"
  x.report "Mysql" do
    mysql_result = mysql.query sql
    fields = mysql_result.fetch_fields
    mysql_result.each do |row|
      row_hash = row.each_with_index.each_with_object({}) do |(f, j), hash|
        hash[fields[j].name.to_sym] = mysql_cast(fields[j].type, f)
      end
      puts row_hash.inspect if debug
    end
  end

  do_mysql = DataObjects::Connection.new("mysql://localhost/#{database}")
  command = do_mysql.create_command sql
  x.report "do_mysql" do
    do_result = command.execute_reader
    do_result.each { |res| puts res.inspect if debug }
  end

  x.compare!
end
