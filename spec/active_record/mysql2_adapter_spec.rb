# encoding: UTF-8
require 'spec_helper'
require 'active_record'
require 'active_record/connection_adapters/mysql2_adapter'

describe ActiveRecord::ConnectionAdapters::Mysql2Adapter do
  before(:all) do
    @connection_options = {
      :adapter  => 'mysql2',
      :host     => 'localhost',
      :database => 'reklabox_test',
      :username => 'root'
    }
  end

  it 'should accept "time_zone" connection configuration option' do
    # Set different time zones and expect different results.
    datetime = '2011-03-26 12:25:49'
    tz_unix_timestamps = {'UTC' => 1301142349, 'Europe/Prague' => 1301138749}
    
    tz_unix_timestamps.each do |time_zone, unix_timestamp|
      ActiveRecord::Base.establish_connection(@connection_options.merge({:time_zone => time_zone}))
      result = ActiveRecord::Base.connection.execute("SELECT UNIX_TIMESTAMP('#{datetime}')")
      result.first.first.should eql(unix_timestamp)
    end
  end
end
