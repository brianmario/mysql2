# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Statement do
  before :each do
    @client = Mysql2::Client.new DatabaseCredentials['root']
  end

  it "should create a statement" do
    statement = nil
    lambda { statement = @client.prepare 'SELECT 1' }.should_not raise_error
    statement.should be_kind_of Mysql2::Statement
  end

  it "should raise an exception when server disconnects" do
    @client.close
    lambda { @client.prepare 'SELECT 1' }.should raise_error(Mysql2::Error)
  end
end
