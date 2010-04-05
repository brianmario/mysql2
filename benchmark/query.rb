# encoding: UTF-8

require 'rubygems'
require 'benchmark'
require 'mysql'
require 'mysql2_ext'
require 'do_mysql'

number_of = 1
database = 'nbb_1_production'
sql = "SELECT * FROM account_entries"

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

  mysql2 = Mysql2::Client.new(:host => "localhost", :username => "root")
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

  do_mysql = DataObjects::Connection.new("mysql://localhost/#{database}")
  command = DataObjects::Mysql::Command.new do_mysql, sql
  x.report do
    puts "do_mysql"
    number_of.times do
      do_result = command.execute_reader
      do_result.each do |res|
        # puts res.inspect
      end
    end
  end
end