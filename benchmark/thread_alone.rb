# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark'
require 'mysql2'

iterations = 1000
client = Mysql2::Client.new(:host => "localhost", :username => "root", :database => "test")
query = lambda{ iterations.times{ client.query("SELECT mysql2_test.* FROM mysql2_test") } }
Benchmark.bmbm do |x|
  x.report('select') do
    query.call
  end
  x.report('rb_thread_select') do
    thread = Thread.new{ sleep(10) }
    query.call
    thread.kill
  end
end