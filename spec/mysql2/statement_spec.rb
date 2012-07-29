# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Statement do
  before :each do
    @client = Mysql2::Client.new :host => "localhost", :username => "root"
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

  it "should tell us the param count" do
    statement = @client.prepare 'SELECT ?, ?'
    statement.param_count.should == 2

    statement2 = @client.prepare 'SELECT 1'
    statement2.param_count.should == 0
  end

  it "should tell us the field count" do
    statement = @client.prepare 'SELECT ?, ?'
    statement.field_count.should == 2

    statement2 = @client.prepare 'SELECT 1'
    statement2.field_count.should == 1
  end

  it "should let us execute our statement" do
    statement = @client.prepare 'SELECT 1'
    statement.execute.should == statement
  end

  it "should raise an exception without a block" do
    statement = @client.prepare 'SELECT 1'
    statement.execute
    lambda { statement.each }.should raise_error
  end

  it "should let us iterate over results" do
    statement = @client.prepare 'SELECT 1'
    statement.execute
    rows = []
    statement.each { |row| rows << row }
    rows.should == [[1]]
  end

  it "should select dates" do
    statement = @client.prepare 'SELECT NOW()'
    statement.execute
    rows = []
    statement.each { |row| rows << row }
    rows.first.first.should be_kind_of Time
  end

  it "should tell us about the fields" do
    statement = @client.prepare 'SELECT 1 as foo, 2'
    statement.execute
    list = statement.fields
    list.length.should == 2
    list.first.should == 'foo'
    list[1].should == '2'
  end

  # it "should let us execute our statement with a param" do
  #   @client.query("USE test")
  #   statement = @client.prepare 'SELECT a FROM t WHERE a = ?'
  #   statement.execute 3
  #   rows = []
  #   statement.each { |row| rows << row }
  #   p rows
  # end
  
  context "utf8_db_field" do
    before(:each) do
      @client.query("DROP DATABASE IF EXISTS test_mysql2_stmt_utf8")
      @client.query("CREATE DATABASE test_mysql2_stmt_utf8")
      @client.query("USE test_mysql2_stmt_utf8")
      @client.query("CREATE TABLE テーブル (整数 int, 文字列 varchar(32)) charset=utf8")
      @client.query("INSERT INTO テーブル (整数, 文字列) VALUES (1, 'イチ'), (2, '弐'), (3, 'さん')")
    end
    
    after(:each) do
      @client.query("DROP DATABASE test_mysql2_stmt_utf8")
    end
    
    it "should be able to retrieve utf8 field names correctly" do
      stmt = @client.prepare 'SELECT * FROM `テーブル`'
      stmt.fields.should == ['整数', '文字列']
      stmt.execute
      
      rows = []
      stmt.each { |row| rows << row }
      p rows
    end
  end
end

