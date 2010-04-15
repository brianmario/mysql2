# encoding: UTF-8
require File.expand_path(File.dirname(__FILE__) + '/../spec_helper.rb')
require 'active_record'
require 'active_record/connection_adapters/mysql2_adapter'

describe ActiveRecord::ConnectionAdapters::Mysql2Adapter do
  it "should be able to connect" do
    lambda {
      ActiveRecord::Base.establish_connection(:adapter => 'mysql2')
    }.should_not raise_error(Mysql2::Error)
  end
  
  context "once connected" do
    before(:each) do
      @connection = ActiveRecord::Base.connection
    end

    it "should be able to execute a raw query" do
      @connection.execute("SELECT 1 as one").first['one'].should eql(1)
      @connection.execute("SELECT NOW() as n").first['n'].class.should eql(Time)
    end
  end
end