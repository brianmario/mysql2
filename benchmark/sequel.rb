$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'mysql2'
require 'sequel'
require 'sequel/adapters/do'

mysql2_opts = "mysql2://root@localhost/test"
mysql_opts = "mysql://root@localhost/test"
do_mysql_opts = "do:mysql://root@localhost/test"

class Mysql2Model < Sequel::Model(Sequel.connect(mysql2_opts)[:mysql2_test]); end
class MysqlModel < Sequel::Model(Sequel.connect(mysql_opts)[:mysql2_test]); end
class DOMysqlModel < Sequel::Model(Sequel.connect(do_mysql_opts)[:mysql2_test]); end

Benchmark.ips do |x|
  x.report "Mysql2" do
    Mysql2Model.limit(1000).all
  end

  x.report "do:mysql" do
    DOMysqlModel.limit(1000).all
  end

  x.report "Mysql" do
    MysqlModel.limit(1000).all
  end

  x.compare!
end
