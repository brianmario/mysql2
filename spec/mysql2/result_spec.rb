# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Result do
  before(:each) do
    @result = @client.query "SELECT 1"
  end

  it "should have included Enumerable" do
    Mysql2::Result.ancestors.include?(Enumerable).should be_true
  end

  it "should respond to #each" do
    @result.should respond_to(:each)
  end

  it "should raise a Mysql2::Error exception upon a bad query" do
    lambda {
      @client.query "bad sql"
    }.should raise_error(Mysql2::Error)

    lambda {
      @client.query "SELECT 1"
    }.should_not raise_error(Mysql2::Error)
  end

  it "should respond to #count, which is aliased as #size" do
    r = @client.query "SELECT 1"
    r.should respond_to :count
    r.should respond_to :size
  end

  it "should be able to return the number of rows in the result set" do
    r = @client.query "SELECT 1"
    r.count.should eql(1)
    r.size.should eql(1)
  end

  context "metadata queries" do
    it "should show tables" do
      @result = @client.query "SHOW TABLES"
    end
  end

  context "#each" do
    it "should yield rows as hash's" do
      @result.each do |row|
        row.class.should eql(Hash)
      end
    end

    it "should yield rows as hash's with symbol keys if :symbolize_keys was set to true" do
      @result.each(:symbolize_keys => true) do |row|
        row.keys.first.class.should eql(Symbol)
      end
    end

    it "should be able to return results as an array" do
      @result.each(:as => :array) do |row|
        row.class.should eql(Array)
      end
    end

    it "should cache previously yielded results by default" do
      @result.first.object_id.should eql(@result.first.object_id)
    end

    it "should not cache previously yielded results if cache_rows is disabled" do
      result = @client.query "SELECT 1", :cache_rows => false
      result.first.object_id.should_not eql(result.first.object_id)
    end

    it "should yield different value for #first if streaming" do
      result = @client.query "SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false
      result.first.should_not eql(result.first)
    end

    it "should yield the same value for #first if streaming is disabled" do
      result = @client.query "SELECT 1 UNION SELECT 2", :stream => false
      result.first.should eql(result.first)
    end

    it "should throw an exception if we try to iterate twice when streaming is enabled" do
      result = @client.query "SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false

      expect {
        result.each.to_a
        result.each.to_a
      }.to raise_exception(Mysql2::Error)
    end
  end

  context "#fields" do
    before(:each) do
      @test_result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1")
    end

    it "method should exist" do
      @test_result.should respond_to(:fields)
    end

    it "should return an array of field names in proper order" do
      result = @client.query "SELECT 'a', 'b', 'c'"
      result.fields.should eql(['a', 'b', 'c'])
    end
  end

  context "streaming" do
    it "should maintain a count while streaming" do
      result = @client.query('SELECT 1')

      result.count.should eql(1)
      result.each.to_a
      result.count.should eql(1)
    end

    it "should set the actual count of rows after streaming" do
      result = @client.query("SELECT * FROM mysql2_test", :stream => true, :cache_rows => false)
      result.count.should eql(0)
      result.each {|r|  }
      result.count.should eql(1)
    end

    it "should not yield nil at the end of streaming" do
      result = @client.query('SELECT * FROM mysql2_test', :stream => true, :cache_rows => false)
      result.each { |r| r.should_not be_nil}
    end

    it "#count should be zero for rows after streaming when there were no results" do
      result = @client.query("SELECT * FROM mysql2_test WHERE null_test IS NOT NULL", :stream => true, :cache_rows => false)
      result.count.should eql(0)
      result.each.to_a
      result.count.should eql(0)
    end

    it "should raise an exception if streaming ended due to a timeout" do
      # Create an extra client instance, since we're going to time it out
      client = Mysql2::Client.new DatabaseCredentials['root']
      client.query "CREATE TEMPORARY TABLE streamingTest (val BINARY(255))"

      # Insert enough records to force the result set into multiple reads
      # (the BINARY type is used simply because it forces full width results)
      10000.times do |i|
        client.query "INSERT INTO streamingTest (val) VALUES ('Foo #{i}')"
      end

      client.query "SET net_write_timeout = 1"
      res = client.query "SELECT * FROM streamingTest", :stream => true, :cache_rows => false

      lambda {
        res.each_with_index do |row, i|
          # Exhaust the first result packet then trigger a timeout
          sleep 2 if i > 0 && i % 1000 == 0
        end
      }.should raise_error(Mysql2::Error, /Lost connection/)
    end
  end

  context "row data type mapping" do
    before(:each) do
      @test_result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
    end

    it "should return nil values for NULL and strings for everything else when :cast is false" do
      result = @client.query('SELECT null_test, tiny_int_test, bool_cast_test, int_test, date_test, enum_test FROM mysql2_test WHERE bool_cast_test = 1 LIMIT 1', :cast => false).first
      result["null_test"].should be_nil
      result["tiny_int_test"].should  eql("1")
      result["bool_cast_test"].should eql("1")
      result["int_test"].should       eql("10")
      result["date_test"].should      eql("2010-04-04")
      result["enum_test"].should      eql("val1")
    end

    it "should return nil for a NULL value" do
      @test_result['null_test'].class.should eql(NilClass)
      @test_result['null_test'].should eql(nil)
    end

    it "should return String for a BIT(64) value" do
      @test_result['bit_test'].class.should eql(String)
      @test_result['bit_test'].should eql("\000\000\000\000\000\000\000\005")
    end

    it "should return String for a BIT(1) value" do
      @test_result['single_bit_test'].class.should eql(String)
      @test_result['single_bit_test'].should eql("\001")
    end

    it "should return Fixnum for a TINYINT value" do
      [Fixnum, Bignum].should include(@test_result['tiny_int_test'].class)
      @test_result['tiny_int_test'].should eql(1)
    end

    it "should return TrueClass or FalseClass for a TINYINT value if :cast_booleans is enabled" do
      @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES (1)'
      id1 = @client.last_id
      @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES (0)'
      id2 = @client.last_id
      @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES (-1)'
      id3 = @client.last_id

      result1 = @client.query 'SELECT bool_cast_test FROM mysql2_test WHERE bool_cast_test = 1 LIMIT 1', :cast_booleans => true
      result2 = @client.query 'SELECT bool_cast_test FROM mysql2_test WHERE bool_cast_test = 0 LIMIT 1', :cast_booleans => true
      result3 = @client.query 'SELECT bool_cast_test FROM mysql2_test WHERE bool_cast_test = -1 LIMIT 1', :cast_booleans => true
      result1.first['bool_cast_test'].should be_true
      result2.first['bool_cast_test'].should be_false
      result3.first['bool_cast_test'].should be_true

      @client.query "DELETE from mysql2_test WHERE id IN(#{id1},#{id2},#{id3})"
    end

    it "should return TrueClass or FalseClass for a BIT(1) value if :cast_booleans is enabled" do
      @client.query 'INSERT INTO mysql2_test (single_bit_test) VALUES (1)'
      id1 = @client.last_id
      @client.query 'INSERT INTO mysql2_test (single_bit_test) VALUES (0)'
      id2 = @client.last_id

      result1 = @client.query "SELECT single_bit_test FROM mysql2_test WHERE id = #{id1}", :cast_booleans => true
      result2 = @client.query "SELECT single_bit_test FROM mysql2_test WHERE id = #{id2}", :cast_booleans => true
      result1.first['single_bit_test'].should be_true
      result2.first['single_bit_test'].should be_false

      @client.query "DELETE from mysql2_test WHERE id IN(#{id1},#{id2})"
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

    it "should return Time for a DATETIME value when within the supported range" do
      @test_result['date_time_test'].class.should eql(Time)
      @test_result['date_time_test'].strftime("%Y-%m-%d %H:%M:%S").should eql('2010-04-04 11:44:00')
    end

    if 1.size == 4 # 32bit
      unless RUBY_VERSION =~ /1.8/
        klass = Time
      else
        klass = DateTime
      end

      it "should return DateTime when timestamp is < 1901-12-13 20:45:52" do
                                      # 1901-12-13T20:45:52 is the min for 32bit Ruby 1.8
        r = @client.query("SELECT CAST('1901-12-13 20:45:51' AS DATETIME) as test")
        r.first['test'].class.should eql(klass)
      end

      it "should return DateTime when timestamp is > 2038-01-19T03:14:07" do
                                      # 2038-01-19T03:14:07 is the max for 32bit Ruby 1.8
        r = @client.query("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test")
        r.first['test'].class.should eql(klass)
      end
    elsif 1.size == 8 # 64bit
      unless RUBY_VERSION =~ /1.8/
        it "should return Time when timestamp is < 1901-12-13 20:45:52" do
          r = @client.query("SELECT CAST('1901-12-13 20:45:51' AS DATETIME) as test")
          r.first['test'].class.should eql(Time)
        end

        it "should return Time when timestamp is > 2038-01-19T03:14:07" do
          r = @client.query("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test")
          r.first['test'].class.should eql(Time)
        end
      else
        it "should return Time when timestamp is > 0138-12-31 11:59:59" do
          r = @client.query("SELECT CAST('0139-1-1 00:00:00' AS DATETIME) as test")
          r.first['test'].class.should eql(Time)
        end

        it "should return DateTime when timestamp is < 0139-1-1T00:00:00" do
          r = @client.query("SELECT CAST('0138-12-31 11:59:59' AS DATETIME) as test")
          r.first['test'].class.should eql(DateTime)
        end

        it "should return Time when timestamp is > 2038-01-19T03:14:07" do
          r = @client.query("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test")
          r.first['test'].class.should eql(Time)
        end
      end
    end

    it "should return Time for a TIMESTAMP value when within the supported range" do
      @test_result['timestamp_test'].class.should eql(Time)
      @test_result['timestamp_test'].strftime("%Y-%m-%d %H:%M:%S").should eql('2010-04-04 11:44:00')
    end

    it "should return Time for a TIME value" do
      @test_result['time_test'].class.should eql(Time)
      @test_result['time_test'].strftime("%Y-%m-%d %H:%M:%S").should eql('2000-01-01 11:44:00')
    end

    it "should return Date for a DATE value" do
      @test_result['date_test'].class.should eql(Date)
      @test_result['date_test'].strftime("%Y-%m-%d").should eql('2010-04-04')
    end

    it "should return String for an ENUM value" do
      @test_result['enum_test'].class.should eql(String)
      @test_result['enum_test'].should eql('val1')
    end

    it "should raise an error given an invalid DATETIME" do
      begin
        @client.query("SELECT CAST('1972-00-27 00:00:00' AS DATETIME) as bad_datetime").each
      rescue Mysql2::Error => e
        error = e
      end

      error.message.should eql("Invalid date in field 'bad_datetime': 1972-00-27 00:00:00")
    end

    if defined? Encoding
      context "string encoding for ENUM values" do
        it "should default to the connection's encoding if Encoding.default_internal is nil" do
          with_internal_encoding nil do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['enum_test'].encoding.should eql(Encoding.find('utf-8'))

            client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
            result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['enum_test'].encoding.should eql(Encoding.find('us-ascii'))
            client2.close
          end
        end

        it "should use Encoding.default_internal" do
          with_internal_encoding 'utf-8' do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['enum_test'].encoding.should eql(Encoding.default_internal)
          end

          with_internal_encoding 'us-ascii' do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['enum_test'].encoding.should eql(Encoding.default_internal)
          end
        end
      end
    end

    it "should return String for a SET value" do
      @test_result['set_test'].class.should eql(String)
      @test_result['set_test'].should eql('val1,val2')
    end

    if defined? Encoding
      context "string encoding for SET values" do
        it "should default to the connection's encoding if Encoding.default_internal is nil" do
          with_internal_encoding nil do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['set_test'].encoding.should eql(Encoding.find('utf-8'))

            client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
            result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['set_test'].encoding.should eql(Encoding.find('us-ascii'))
            client2.close
          end
        end

        it "should use Encoding.default_internal" do
          with_internal_encoding 'utf-8' do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['set_test'].encoding.should eql(Encoding.default_internal)
          end

          with_internal_encoding 'us-ascii' do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['set_test'].encoding.should eql(Encoding.default_internal)
          end
        end
      end
    end

    it "should return String for a BINARY value" do
      @test_result['binary_test'].class.should eql(String)
      @test_result['binary_test'].should eql("test#{"\000"*6}")
    end

    if defined? Encoding
      context "string encoding for BINARY values" do
        it "should default to binary if Encoding.default_internal is nil" do
          with_internal_encoding nil do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['binary_test'].encoding.should eql(Encoding.find('binary'))
          end
        end

        it "should not use Encoding.default_internal" do
          with_internal_encoding 'utf-8' do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['binary_test'].encoding.should eql(Encoding.find('binary'))
          end

          with_internal_encoding 'us-ascii' do
            result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
            result['binary_test'].encoding.should eql(Encoding.find('binary'))
          end
        end
      end
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

      if defined? Encoding
        context "string encoding for #{type} values" do
          if ['VARBINARY', 'TINYBLOB', 'BLOB', 'MEDIUMBLOB', 'LONGBLOB'].include?(type)
            it "should default to binary if Encoding.default_internal is nil" do
              with_internal_encoding nil do
                result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
                result['binary_test'].encoding.should eql(Encoding.find('binary'))
              end
            end

            it "should not use Encoding.default_internal" do
              with_internal_encoding 'utf-8' do
                result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
                result['binary_test'].encoding.should eql(Encoding.find('binary'))
              end

              with_internal_encoding 'us-ascii' do
                result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
                result['binary_test'].encoding.should eql(Encoding.find('binary'))
              end
            end
          else
            it "should default to utf-8 if Encoding.default_internal is nil" do
              with_internal_encoding nil do
                result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
                result[field].encoding.should eql(Encoding.find('utf-8'))

                client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
                result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
                result[field].encoding.should eql(Encoding.find('us-ascii'))
                client2.close
              end
            end

            it "should use Encoding.default_internal" do
              with_internal_encoding 'utf-8' do
                result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
                result[field].encoding.should eql(Encoding.default_internal)
              end

              with_internal_encoding 'us-ascii' do
                result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
                result[field].encoding.should eql(Encoding.default_internal)
              end
            end
          end
        end
      end
    end
  end
end
