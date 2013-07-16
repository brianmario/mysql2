# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark'
require 'active_record'

ActiveRecord::Base.default_timezone = :local
ActiveRecord::Base.time_zone_aware_attributes = true

number_of = 10
mysql2_opts = {
  :adapter => 'mysql2',
  :database => 'test'
}
mysql_opts = {
  :adapter => 'mysql',
  :database => 'test'
}

class Mysql2Model < ActiveRecord::Base
  self.table_name = "mysql2_test"
end

class MysqlModel < ActiveRecord::Base
  self.table_name = "mysql2_test"
end

Benchmark.bmbm do |x|
  x.report "Mysql2" do
    Mysql2Model.establish_connection(mysql2_opts)
    number_of.times do
      Mysql2Model.limit(1000).to_a.each{ |r|
        r.attributes.keys.each{ |k|
          r.send(k.to_sym)
        }
      }
    end
  end

  x.report "Mysql" do
    MysqlModel.establish_connection(mysql_opts)
    number_of.times do
      MysqlModel.limit(1000).to_a.each{ |r|
        r.attributes.keys.each{ |k|
          r.send(k.to_sym)
        }
      }
    end
  end
end
