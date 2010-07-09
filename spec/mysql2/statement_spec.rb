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

  it "should tell us the field count" do
    stmt = @client.create_statement
    stmt.prepare 'SELECT ?, ?'
    stmt.field_count.should == 2

    stmt.prepare 'SELECT 1'
    stmt.field_count.should == 1
  end

  it "should let us execute our statement" do
    stmt = @client.create_statement
    stmt.prepare 'SELECT 1'
    stmt.execute.should == stmt
  end

  it "should raise an exception on error" do
    stmt = @client.create_statement
    lambda { stmt.execute }.should raise_error(Mysql2::Error)
  end

  it "should raise an exception without a block" do
    stmt = @client.create_statement
    stmt.prepare 'SELECT 1'
    stmt.execute
    lambda { stmt.each }.should raise_error
  end

  it "should let us iterate over results" do
    stmt = @client.create_statement
    stmt.prepare 'SELECT 1'
    stmt.execute
    rows = []
    stmt.each { |row| rows << row }
    pending "not working yet"
    rows.should == [[1]]
  end

  it "should tell us about the fields" do
    stmt = @client.create_statement
    stmt.prepare 'SELECT 1 as foo, 2'
    stmt.execute
    list = stmt.fields
    list.length.should == 2
    list.first.name.should == 'foo'
    list[1].name.should == '2'
  end
end
