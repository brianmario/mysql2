# encoding: UTF-8

require 'rubygems'
require 'benchmark'
require 'mysql'
require 'mysql2_ext'

number_of = 1000
database = 'nbb_1_production'
str = "abc'def\"ghi\0jkl%mno"

Benchmark.bmbm do |x|
  mysql = Mysql.new("localhost", "root")
  mysql.query "USE #{database}"
  x.report do
    puts "Mysql"
    number_of.times do
      mysql.escape_string str
    end
  end

  mysql2 = Mysql2::Client.new(:host => "localhost", :username => "root")
  mysql2.query "USE #{database}"
  x.report do
    puts "Mysql2"
    number_of.times do
      mysql2.escape str
    end
  end
end