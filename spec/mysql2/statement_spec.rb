# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Statement do
  before :each do
    @client = Mysql2::Client.new :host => "localhost", :username => "root"
  end

  it "should create a statement" do
    stmt = @client.create_statement
    stmt.should be_kind_of Mysql2::Statement
  end

  it "prepares some sql" do
    stmt = @client.create_statement
    lambda { stmt.prepare 'SELECT 1' }.should_not raise_error
  end

  it "return self when prepare some sql" do
    stmt = @client.create_statement
    stmt.prepare('SELECT 1').should == stmt
  end

  it "should raise an exception when server disconnects" do
    stmt = @client.create_statement
    @client.close
    lambda { stmt.prepare 'SELECT 1' }.should raise_error(Mysql2::Error)
  end

  it "should tell us the param count" do
    stmt = @client.create_statement
    stmt.prepare 'SELECT ?, ?'
    stmt.param_count.should == 2

    stmt.prepare 'SELECT 1'
    stmt.param_count.should == 0
  end
end
