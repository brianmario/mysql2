# encoding: UTF-8
require 'spec_helper'
require 'active_record'
require 'active_record/connection_adapters/mysql2_adapter'

describe ActiveRecord::ConnectionAdapters::Mysql2Adapter do
  before(:all) do
    @connection_options = {
      :adapter  => 'mysql2',
      :host     => 'localhost',
      :database => 'test',
      :username => 'root'
    }
  end

  it 'should accept "time_zone" connection configuration option' do
    # Set different time zones and expect different results.
    time_zones = ['Australia/Sydney', 'Europe/Prague']
    
    time_zones.each do |time_zone|
      ActiveRecord::Base.establish_connection(@connection_options.merge({:time_zone => time_zone}))
      result = ActiveRecord::Base.connection.execute("SELECT @@session.time_zone")
      result.first.first.should eql(time_zone)
    end
  end
end
