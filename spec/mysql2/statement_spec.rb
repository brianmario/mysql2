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

  context "parameter substitution" do

    # Test all different types of parameter explicitly dealt with
    let(:some_fixnum) { 1 }
    let(:some_bignum) { 723623523423323223123 }
    let(:some_bigdecimal) { BigDecimal.new(1.25, 2) }
    let(:some_float) { 2.4 }
    let(:some_string) { "blah" }
    let(:some_time) { Time.now }
    let(:some_datetime) { DateTime.now}
    let(:some_date) { Date.today }

    it "tests with correct types" do
      some_bignum.should be_a(Bignum)
      some_fixnum.should be_a(Fixnum)
      some_bigdecimal.should be_a(BigDecimal)
      some_float     .should be_a(Float)
      some_string    .should be_a(String)
      some_time.      should be_a(Time)
      some_datetime.  should be_a(DateTime)
      some_date.      should be_a(Date)
    end

    it "should pass in nil parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT 1 as foo, 2) bar WHERE foo = ?'
      statement.execute(nil).should == statement
    end

    it "should pass in Fixnum parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT 1 as foo, 2) bar WHERE foo = ?'
      statement.execute(some_fixnum).should == statement
    end

    it "should pass in Bignum parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT 1 as foo, 2) bar WHERE foo = ?'
      (lambda{ statement.execute(some_bignum) }).should raise_error(RangeError)
    end

    it "should pass in BigDecimal parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT 1 as foo, 2) bar WHERE foo = ?'
      statement.execute(some_bigdecimal).should == statement
    end

    it "should pass in Float parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT 2.3 as foo, 2) bar WHERE foo = ?'
      statement.execute(some_float).should == statement
    end

    it "should pass in String parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT "foo" as foo, 2) bar WHERE foo = ?'
      statement.execute(some_string).should == statement
    end

    it "should pass in Time parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT CURRENT_TIMESTAMP() as foo, 2) bar WHERE foo = ?'
      statement.execute(some_time).should == statement
    end

    it "should pass in DateTime parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT CURRENT_TIMESTAMP() as foo, 2) bar WHERE foo = ?'
      statement.execute(some_datetime).should == statement
    end

    it "should pass in Date parameters" do
      statement = @client.prepare 'SELECT * FROM (SELECT CURRENT_DATE() as foo, 2) bar WHERE foo = ?'
      statement.execute(some_date).should == statement
    end

  end
end
