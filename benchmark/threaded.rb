# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark'
require 'active_record'

mysql2_opts = {
  :adapter => 'mysql2',
  :database => 'test',
  :pool => 25
}
ActiveRecord::Base.establish_connection(mysql2_opts)
x = Benchmark.realtime do
  threads = []
  25.times do
    threads << Thread.new { ActiveRecord::Base.connection.execute("select sleep(1)") }
  end
  threads.each {|t| t.join }
end
puts x

mysql2_opts = {
  :adapter => 'mysql',
  :database => 'test',
  :pool => 25
}
ActiveRecord::Base.establish_connection(mysql2_opts)
x = Benchmark.realtime do
  threads = []
  25.times do
    threads << Thread.new { ActiveRecord::Base.connection.execute("select sleep(1)") }
  end
  threads.each {|t| t.join }
end
puts x

# these results are similar on 1.8.7, 1.9.2 and rbx-head
#
# $ bundle exec ruby benchmarks/threaded.rb
# 1.0774750709533691
#
# and using the mysql gem
# 25.099437952041626