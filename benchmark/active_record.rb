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
  set_table_name :mysql2_test
end

class Mysql2Model2 < ActiveRecord::Base
  set_table_name :mysql2_test
end

class MysqlModel < ActiveRecord::Base
  set_table_name :mysql2_test
end

Mysql2Model.establish_connection(mysql2_opts)

Mysql2Model2.establish_connection(mysql2_opts)
connection = Mysql2Model2.connection.instance_variable_get "@connection"
connection.query_options[:cast_dates]        = false
connection.query_options[:cast_datetimes]    = false

Benchmark.bmbm do |x|
  x.report "Mysql2 (with auto casting, no attr access)" do
    number_of.times do
      Mysql2Model.all(:limit => 1000)
    end
  end

  x.report "Mysql2 (with lazy casting, no attr access)" do
    number_of.times do
      Mysql2Model2.all(:limit => 1000)
    end
  end

  x.report "Mysql (with lazy casting, no attr access)" do
    MysqlModel.establish_connection(mysql_opts)
    number_of.times do
      MysqlModel.all(:limit => 1000)
    end
  end
end

GC.start
puts
puts
Benchmark.bmbm do |x|
  x.report "Mysql2 (with auto casting, read date/datetime/timestamp attrs)" do
    number_of.times do
      Mysql2Model.all(:limit => 1000).each{ |r|
        r.date_test
        r.date_time_test
        r.timestamp_test
      }
    end
  end

  x.report "Mysql2 (with lazy casting, read date/datetime/timestamp attrs)" do
    number_of.times do
      Mysql2Model2.all(:limit => 1000).each{ |r|
        r.date_test
        r.date_time_test
        r.timestamp_test
      }
    end
  end

  x.report "Mysql (with lazy casting, read date/datetime/timestamp attrs)" do
    MysqlModel.establish_connection(mysql_opts)
    number_of.times do
      MysqlModel.all(:limit => 1000).each{ |r|
        r.date_test
        r.date_time_test
        r.timestamp_test
      }
    end
  end
end

GC.start
puts
puts
Benchmark.bmbm do |x|
  x.report "Mysql2 (with auto casting, read all attrs)" do
    number_of.times do
      Mysql2Model.all(:limit => 1000).each{ |r|
        r.attributes.keys.each{ |k|
          r.send(k.to_sym)
        }
      }
    end
  end

  x.report "Mysql2 (with lazy casting, read all attrs)" do
    number_of.times do
      Mysql2Model2.all(:limit => 1000).each{ |r|
        r.attributes.keys.each{ |k|
          r.send(k.to_sym)
        }
      }
    end
  end

  x.report "Mysql (with lazy casting, read all attrs)" do
    MysqlModel.establish_connection(mysql_opts)
    number_of.times do
      MysqlModel.all(:limit => 1000).each{ |r|
        r.attributes.keys.each{ |k|
          r.send(k.to_sym)
        }
      }
    end
  end
end