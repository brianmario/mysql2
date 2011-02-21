# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark'
require 'mysql2'
require 'sequel'
require 'sequel/adapters/do'

number_of = 10
mysql2_opts = "mysql2://localhost/test"
mysql_opts = "mysql://localhost/test"
do_mysql_opts = "do:mysql://localhost/test"

class Mysql2Model < Sequel::Model(Sequel.connect(mysql2_opts)[:mysql2_test]); end
class MysqlModel < Sequel::Model(Sequel.connect(mysql_opts)[:mysql2_test]); end
class DOMysqlModel < Sequel::Model(Sequel.connect(do_mysql_opts)[:mysql2_test]); end

Benchmark.bmbm do |x|
  x.report "Mysql2" do
    number_of.times do
      Mysql2Model.limit(1000).all
    end
  end

  x.report "do:mysql" do
    number_of.times do
      DOMysqlModel.limit(1000).all
    end
  end

  x.report "Mysql" do
    number_of.times do
      MysqlModel.limit(1000).all
    end
  end
end