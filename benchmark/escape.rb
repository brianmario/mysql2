# encoding: UTF-8

require 'rubygems'
require 'benchmark'
require 'mysql'
require 'mysql2_ext'
require 'do_mysql'

number_of = 1000
str = "abc'def\"ghi\0jkl%mno"

Benchmark.bmbm do |x|
  mysql = Mysql.new("localhost", "root")
  x.report do
    puts "Mysql"
    number_of.times do
      mysql.quote str
    end
  end

  mysql2 = Mysql2::Client.new(:host => "localhost", :username => "root")
  x.report do
    puts "Mysql2"
    number_of.times do
      mysql2.escape str
    end
  end

  do_mysql = DataObjects::Connection.new("mysql://localhost/test")
  x.report do
    puts "do_mysql"
    number_of.times do
      do_mysql.quote_string str
    end
  end
end