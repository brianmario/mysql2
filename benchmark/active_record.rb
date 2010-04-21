# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark'
require 'active_record'

number_of = 10
mysql2_opts = {
  :adapter => 'mysql2',
  :database => 'test'
}
mysql_opts = {
  :adapter => 'mysql',
  :database => 'test'
}

class TestModel < ActiveRecord::Base
  set_table_name :mysql2_test
end

Benchmark.bmbm do |x|
  x.report do
    TestModel.establish_connection(mysql2_opts)
    puts "Mysql2"
    number_of.times do
      TestModel.all(:limit => 1000)
    end
  end

  x.report do
    TestModel.establish_connection(mysql_opts)
    puts "Mysql"
    number_of.times do
      TestModel.all(:limit => 1000)
    end
  end
end