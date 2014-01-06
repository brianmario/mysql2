# encoding: UTF-8
$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark'
require 'active_record'

raise Mysql2::Error.new("GC allocation benchmarks only supported on Ruby 1.9!") unless RUBY_VERSION > '1.9'

ActiveRecord::Base.default_timezone = :local
ActiveRecord::Base.time_zone_aware_attributes = true

class Mysql2Model < ActiveRecord::Base
  self.table_name = "mysql2_test"
end

def bench_allocations(feature, iterations = 10, &blk)
  puts "GC overhead for #{feature}"
  Mysql2Model.establish_connection(:adapter => 'mysql2', :database => 'test')
  GC::Profiler.clear
  GC::Profiler.enable
  iterations.times{ blk.call }
  GC::Profiler.report(STDOUT)
  GC::Profiler.disable
end

bench_allocations('coercion') do
  Mysql2Model.limit(1000).to_a.each{ |r|
    r.attributes.keys.each{ |k|
      r.send(k.to_sym)
    }
  }
end
