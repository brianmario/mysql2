# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark'
require 'active_record'

times = 25


# mysql2
mysql2_opts = {
  :adapter => 'mysql2',
  :database => 'test',
  :pool => times
}
ActiveRecord::Base.establish_connection(mysql2_opts)
x = Benchmark.realtime do
  threads = []
  times.times do
    threads << Thread.new { ActiveRecord::Base.connection.execute("select sleep(1)") }
  end
  threads.each {|t| t.join }
end
puts "mysql2: #{x} seconds"


# mysql
mysql2_opts = {
  :adapter => 'mysql',
  :database => 'test',
  :pool => times
}
ActiveRecord::Base.establish_connection(mysql2_opts)
x = Benchmark.realtime do
  threads = []
  times.times do
    threads << Thread.new { ActiveRecord::Base.connection.execute("select sleep(1)") }
  end
  threads.each {|t| t.join }
end
puts "mysql: #{x} seconds"
