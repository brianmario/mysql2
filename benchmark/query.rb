# encoding: UTF-8

require 'rubygems'
require 'benchmark'
require 'mysql'
require 'mysql2_ext'

number_of = 1
database = 'nbb_1_production'
sql = "SELECT * FROM account_transactions"

Benchmark.bmbm do |x|
  mysql = Mysql.new("localhost", "root")
  mysql.query "USE #{database}"
  x.report do
    puts "Mysql"
    number_of.times do
      mysql_result = mysql.query sql
      mysql_result.each_hash do |res|
        # puts res.inspect
      end
    end
  end

  mysql2 = Mysql2::Client.new
  mysql2.query "USE #{database}"
  x.report do
    puts "Mysql2"
    number_of.times do
      mysql2_result = mysql2.query sql
      mysql2_result.each(:symbolize_keys => true) do |res|
        # puts res.inspect
      end
    end
  end
end