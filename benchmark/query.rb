# encoding: UTF-8

require 'rubygems'
require 'benchmark'
require 'mysql'
require 'mysql2_ext'

number_of = 100

Benchmark.bmbm do |x|
  GC.start
  mysql = Mysql.new("localhost", "root")
  mysql.query "USE nbb_development"
  x.report do
    puts "Mysql"
    number_of.times do
      mysql_result = mysql.query "SELECT * FROM account_transactions"
      mysql_result.each_hash do |res| end
    end
  end

  GC.start
  mysql2 = Mysql2::Client.new
  mysql2.query "USE nbb_development"
  x.report do
    puts "Mysql2"
    number_of.times do
      mysql2_result = mysql2.query "SELECT * FROM account_transactions"
      mysql2_result.each do |res| end
    end
  end
end