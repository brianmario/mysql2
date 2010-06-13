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

  it "should raise a Mysql2::Error exception upon a bad query" do
    lambda {
      @client.query "bad sql"
    }.should raise_error(Mysql2::Error)

    lambda {
      @client.query "SELECT 1"
    }.should_not raise_error(Mysql2::Error)
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

    it "should cache previously yielded results" do
      @result.first.should eql(@result.first)
    end
  end

  context "row data type mapping" do
    before(:all) do
      @client.query "USE test"
      @client.query %[
        CREATE TABLE IF NOT EXISTS mysql2_test (
          id MEDIUMINT NOT NULL AUTO_INCREMENT,
          null_test VARCHAR(10),
          bit_test BIT(64),
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
          binary_test BINARY(10),
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
          set_test SET('val1', 'val2'),
          PRIMARY KEY (id)
        )
      ]
      @client.query %[
        INSERT INTO mysql2_test (
          null_test, bit_test, tiny_int_test, small_int_test, medium_int_test, int_test, big_int_test,
          float_test, double_test, decimal_test, date_test, date_time_test, timestamp_test, time_test,
          year_test, char_test, varchar_test, binary_test, varbinary_test, tiny_blob_test,
          tiny_text_test, blob_test, text_test, medium_blob_test, medium_text_test,
          long_blob_test, long_text_test, enum_test, set_test
        )

        VALUES (
          NULL, b'101', 1, 10, 10, 10, 10,
          10.3, 10.3, 10.3, '2010-4-4', '2010-4-4 11:44:00', '2010-4-4 11:44:00', '11:44:00',
          2009, "test", "test", "test", "test", "test",
          "test", "test", "test", "test", "test",
          "test", "test", 'val1', 'val1,val2'
        )
      ]
      @test_result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
    end

    after(:all) do
      @client.query("DELETE FROM mysql2_test WHERE id=#{@test_result['id']}")
    end

    it "should return nil for a NULL value" do
      @test_result['null_test'].class.should eql(NilClass)
      @test_result['null_test'].should eql(nil)
    end

    it "should return Fixnum for a BIT value" do
      @test_result['bit_test'].class.should eql(String)
      @test_result['bit_test'].should eql("\000\000\000\000\000\000\000\005")
    end

    it "should return Fixnum for a TINYINT value" do
      [Fixnum, Bignum].should include(@test_result['tiny_int_test'].class)
      @test_result['tiny_int_test'].should eql(1)
    end

    it "should return Fixnum for a SMALLINT value" do
      [Fixnum, Bignum].should include(@test_result['small_int_test'].class)
      @test_result['small_int_test'].should eql(10)
    end

    it "should return Fixnum for a MEDIUMINT value" do
      [Fixnum, Bignum].should include(@test_result['medium_int_test'].class)
      @test_result['medium_int_test'].should eql(10)
    end

    it "should return Fixnum for an INT value" do
      [Fixnum, Bignum].should include(@test_result['int_test'].class)
      @test_result['int_test'].should eql(10)
    end

    it "should return Fixnum for a BIGINT value" do
      [Fixnum, Bignum].should include(@test_result['big_int_test'].class)
      @test_result['big_int_test'].should eql(10)
    end

    it "should return Fixnum for a YEAR value" do
      [Fixnum, Bignum].should include(@test_result['year_test'].class)
      @test_result['year_test'].should eql(2009)
    end

    it "should return BigDecimal for a DECIMAL value" do
      @test_result['decimal_test'].class.should eql(BigDecimal)
      @test_result['decimal_test'].should eql(10.3)
    end

    it "should return Float for a FLOAT value" do
      @test_result['float_test'].class.should eql(Float)
      @test_result['float_test'].should eql(10.3)
    end

    it "should return Float for a DOUBLE value" do
      @test_result['double_test'].class.should eql(Float)
      @test_result['double_test'].should eql(10.3)
    end

    it "should return Time for a DATETIME value" do
      @test_result['date_time_test'].class.should eql(Time)
      @test_result['date_time_test'].strftime("%F %T").should eql('2010-04-04 11:44:00')
    end

    it "should return Time for a TIMESTAMP value" do
      @test_result['timestamp_test'].class.should eql(Time)
      @test_result['timestamp_test'].strftime("%F %T").should eql('2010-04-04 11:44:00')
    end

    it "should return Time for a TIME value" do
      @test_result['time_test'].class.should eql(Time)
      if RUBY_VERSION >= "1.9.2"
        @test_result['time_test'].strftime("%F %T").should eql('0000-01-01 11:44:00')
      else
        @test_result['time_test'].strftime("%F %T").should eql('2000-01-01 11:44:00')
      end
    end

    it "should return Date for a DATE value" do
      @test_result['date_test'].class.should eql(Date)
      @test_result['date_test'].strftime("%F").should eql('2010-04-04')
    end

    it "should return String for an ENUM value" do
      @test_result['enum_test'].class.should eql(String)
      @test_result['enum_test'].should eql('val1')
    end

    it "should return String for a SET value" do
      @test_result['set_test'].class.should eql(String)
      @test_result['set_test'].should eql('val1,val2')
    end

    it "should return String for a BINARY value" do
      @test_result['binary_test'].class.should eql(String)
      @test_result['binary_test'].should eql("test#{"\000"*6}")
    end

    {
      'char_test' => 'CHAR',
      'varchar_test' => 'VARCHAR',
      'varbinary_test' => 'VARBINARY',
      'tiny_blob_test' => 'TINYBLOB',
      'tiny_text_test' => 'TINYTEXT',
      'blob_test' => 'BLOB',
      'text_test' => 'TEXT',
      'medium_blob_test' => 'MEDIUMBLOB',
      'medium_text_test' => 'MEDIUMTEXT',
      'long_blob_test' => 'LONGBLOB',
      'long_text_test' => 'LONGTEXT'
    }.each do |field, type|
      it "should return a String for #{type}" do
        @test_result[field].class.should eql(String)
        @test_result[field].should eql("test")
      end
    end
  end
end