$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'active_record'

ActiveRecord::Base.default_timezone = :local
ActiveRecord::Base.time_zone_aware_attributes = true

class TestModel < ActiveRecord::Base
  self.table_name = 'mysql2_test'
end

def bench_allocations(feature, iterations = 10, batch_size = 1000)
  puts "GC overhead for #{feature}"
  TestModel.establish_connection(adapter: 'mysql2', database: 'test')
  GC::Profiler.clear
  GC::Profiler.enable
  iterations.times { yield batch_size }
  GC::Profiler.report(STDOUT)
  GC::Profiler.disable
end

bench_allocations('coercion') do |batch_size|
  TestModel.limit(batch_size).to_a.each do |r|
    r.attributes.each_key do |k|
      r.send(k.to_sym)
    end
  end
end
