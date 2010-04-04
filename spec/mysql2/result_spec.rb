# encoding: UTF-8
require File.expand_path(File.dirname(__FILE__) + '/../spec_helper.rb')

describe Mysql2::Result do
  before(:all) do
    @client = Mysql2::Client.new :host => "localhost", :username => "root"
  end

  before(:each) do
    @result = @client.query "SELECT 1"
  end

  it "should have included Enumerable" do
    Mysql2::Result.ancestors.include?(Enumerable).should be_true
  end

  it "should respond to #each" do
    @result.should respond_to :each
  end

  context "#each" do
    it "should yield rows as hash's" do
      @result.each do |row|
        row.class.should eql(Hash)
      end
    end

    it "should yield rows as hash's with symbol keys if :symbolize_keys was set to true" do
      @result.each(:symbolize_keys => true) do |row|
        row.class.should eql(Hash)
        row.keys.first.class.should eql(Symbol)
      end
    end
  end

  context "row data type mapping" do
    before(:all) do
      @client.query "CREATE DATABASE mysql2_test_db"
      @client.query "USE mysql2_test_db"
      @client.query %[
        CREATE TABLE mysql2_test (
          null_test VARCHAR(10),
          bit_test BIT,
          tiny_int_test TINYINT,
          small_int_test SMALLINT,
          medium_int_test MEDIUMINT,
          int_test INT,
          big_int_test BIGINT,
          float_test FLOAT(10,3),
          double_test DOUBLE(10,3),
          decimal_test DECIMAL(10,3),
          date_test DATE,
          date_time_test DATETIME,
          timestamp_test TIMESTAMP,
          time_test TIME,
          year_test YEAR(4),
          char_test CHAR(10),
          varchar_test VARCHAR(10),
          binary_test BINARY,
          varbinary_test VARBINARY(10),
          tiny_blob_test TINYBLOB,
          tiny_text_test TINYTEXT,
          blob_test BLOB,
          text_test TEXT,
          medium_blob_test MEDIUMBLOB,
          medium_text_test MEDIUMTEXT,
          long_blob_test LONGBLOB,
          long_text_test LONGTEXT,
          enum_test ENUM('val1', 'val2'),
          set_test SET('val1', 'val2')
        )
      ]
      @client.query %[
        INSERT INTO mysql2_test (
          null_test, bit_test, tiny_int_test, small_int_test, medium_int_test, int_test, big_int_test,
          float_test, double_test, date_test, date_time_test, timestamp_test, time_test,
          year_test, char_test, varchar_test, binary_test, varbinary_test, tiny_blob_test,
          tiny_text_test, blob_test, text_test, medium_blob_test, medium_text_test,
          long_blob_test, long_text_test, enum_test, set_test
        )

        VALUES (
          NULL, 1, 1, 10, 10, 10, 10,
          10.3, 10.3, '2010-4-4', '2010-4-4 11:44:00', '2010-4-4 11:44:00', '11:44:00',
          2009, "test", "test", "test", "test", "test",
          "test", "test", "test", "test", "test",
          "test", "test", 'val1', 'val1 val2'
        )
      ]
      @test_result = @client.query("SELECT * FROM mysql2_test LIMIT 1").first
    end

    after(:all) do
      @client.query "DROP DATABASE mysql2_test_db"
    end

    it "should return nil for a NULL value" do
      @test_result['null_test'].should eql(nil)
      @test_result['null_test'].class.should eql(NilClass)
    end

    {
      'bit_test' => 'BIT',
      'tiny_int_test' => 'TINYINT',
      'small_int_test' => 'SMALLINT',
      'medium_int_test' => 'MEDIUMINT',
      'int_test' => 'INT',
      'big_int_test' => 'BIGINT',
      'year_test' => 'YEAR'
    }.each do |field, type|
      it "should return a Fixnum for #{type}" do
        @test_result[field].class.should eql(Fixnum)
      end
    end

    {
      'float_test' => 'FLOAT',
      'double_test' => 'DOUBLE'
    }.each do |field, type|
      it "should return a Float for #{type}" do
        @test_result[field].class.should eql(Float)
      end
    end

    {
      'date_test' => 'DATE',
      'date_time_test' => 'DATETIME',
      'timestamp_test' => 'TIMESTAMP',
      'time_test' => 'TIME'
    }.each do |field, type|
      it "should return a Time for #{type}" do
        @test_result[field].class.should eql(Time)
      end
    end

    {
      'char_test' => 'CHAR',
      'varchar_test' => 'VARCHAR',
      'binary_test' => 'BINARY',
      'varbinary_test' => 'VARBINARY',
      'tiny_blob_test' => 'TINYBLOB',
      'tiny_text_test' => 'TINYTEXT',
      'blob_test' => 'BLOB',
      'text_test' => 'TEXT',
      'medium_blob_test' => 'MEDIUMBLOB',
      'medium_text_test' => 'MEDIUMTEXT',
      'long_blob_test' => 'LONGBLOB',
      'long_text_test' => 'LONGTEXT',
      'enum_test' => 'ENUM',
      'set_test' => 'SET',
    }.each do |field, type|
      it "should return a String for #{type}" do
        @test_result[field].class.should eql(String)
      end
    end
  end
end