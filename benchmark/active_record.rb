$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'active_record'

ActiveRecord::Base.default_timezone = :local
ActiveRecord::Base.time_zone_aware_attributes = true

opts = { database: 'test' }

class TestModel < ActiveRecord::Base
  self.table_name = 'mysql2_test'
end

batch_size = 1000

Benchmark.ips do |x|
  %w[mysql mysql2].each do |adapter|
    TestModel.establish_connection(opts.merge(adapter: adapter))

    x.report(adapter) do
      TestModel.limit(batch_size).to_a.each do |r|
        r.attributes.each_key do |k|
          r.send(k.to_sym)
        end
      end
    end
  end

  x.compare!
end
