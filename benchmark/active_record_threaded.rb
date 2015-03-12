# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'active_record'

number_of_threads = 25
opts = { :database => 'test', :pool => number_of_threads }

Benchmark.ips do |x|
  %w(mysql mysql2).each do |adapter|
    ActiveRecord::Base.establish_connection(opts.merge(:adapter => adapter))

    x.report(adapter) do
      number_of_threads.times.map do
        Thread.new { ActiveRecord::Base.connection.execute('SELECT SLEEP(1)') }
      end.each(&:join)
    end
  end

  x.compare!
end
