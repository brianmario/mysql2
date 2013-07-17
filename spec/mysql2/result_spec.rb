# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Result do
  before(:each) do
    @result = @client.query "SELECT 1"
  end

  test "maintains a count while streaming" do
    result = @client.query('SELECT 1')

    assert_equal 1, result.count
    result.each.to_a
    assert_equal 1, result.count
  end

  test "sets the actual count of rows after streaming" do
      @client.query "USE test"
      result = @client.query("SELECT * FROM mysql2_test", :stream => true, :cache_rows => false)
      assert_equal 0, result.count
      result.each {|r|  }
      assert_equal 1, result.count
  end

  test "doesn't yield nil at the end of streaming" do
    result = @client.query('SELECT * FROM mysql2_test', :stream => true)
    result.each { |r| assert !r.nil?}
  end

  test "#count is zero for rows after streaming when there were no results " do
      @client.query "USE test"
      result = @client.query("SELECT * FROM mysql2_test WHERE null_test IS NOT NULL", :stream => true, :cache_rows => false)
      assert_equal 0, result.count
      result.each.to_a
      assert_equal 0, result.count
  end

  test "includes Enumerable" do
    assert Mysql2::Result.ancestors.include?(Enumerable)
  end

  test "responds to #each" do
    assert @result.respond_to?(:each)
  end

  test "raises a Mysql2::Error exception upon a bad query" do
    assert_raises Mysql2::Error do
      @client.query "bad sql"
    end

    assert_not_raised Mysql2::Error do
      @client.query "SELECT 1"
    end
  end

  test "responds to #count, which is aliased as #size" do
    r = @client.query "SELECT 1"
    assert r.respond_to? :count
    assert r.respond_to? :size
  end

  test "returns the number of rows in the result set" do
    r = @client.query "SELECT 1"
    assert_equal 1, r.count
    assert_equal 1, r.size
  end

  context "metadata queries" do
    test "shows tables" do
      @result = @client.query "SHOW TABLES"
    end
  end

  context "#each" do
    test "yields rows as hashes by default" do
      @result.each do |row|
        assert_equal Hash, row.class
      end
    end

    test "yields rows as hashes with symbol keys if :symbolize_keys was set to true" do
      @result.each(:symbolize_keys => true) do |row|
        assert_equal Symbol, row.keys.first.class
      end
    end

    test "yields rows as an array if :as => :array is set" do
      @result.each(:as => :array) do |row|
        assert_equal Array, row.class
      end
    end

    test "caches previously yielded results by default" do
      assert_equal @result.first.object_id, @result.first.object_id
    end

    test "doesn't cache previously yielded results if cache_rows is disabled" do
      result = @client.query "SELECT 1", :cache_rows => false
      assert_not_equal result.first.object_id, result.first.object_id
    end

    test "yields different value for #first if streaming" do
      result = @client.query "SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false
      assert_not_equal result.first, result.first
    end

    test "yields the same value for #first if streaming is disabled" do
      result = @client.query "SELECT 1 UNION SELECT 2", :stream => false
      assert_equal result.first, result.first
    end

    test "raises an exception if we try to iterate twice when streaming is enabled" do
      result = @client.query "SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false

      assert_raises Mysql2::Error do
        result.each.to_a
        result.each.to_a
      end
    end
  end

  context "#fields" do
    before(:each) do
      @client.query "USE test"
      @test_result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1")
    end

    test "method exists" do
      assert @test_result.respond_to?(:fields)
    end

    test "returns an array of field names in proper order" do
      result = @client.query "SELECT 'a', 'b', 'c'"
      assert_equal ['a', 'b', 'c'], result.fields
    end
  end

  context "row data type mapping" do
    before(:each) do
      @client.query "USE test"
      @test_result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
    end

    test "returns nil values for NULL and strings for everything else when :cast is false" do
      result = @client.query('SELECT null_test, tiny_int_test, bool_cast_test, int_test, date_test, enum_test FROM mysql2_test WHERE bool_cast_test = 1 LIMIT 1', :cast => false).first
      assert_nil result["null_test"]
      assert_equal "1", result["tiny_int_test"]
      assert_equal "1", result["bool_cast_test"]
      assert_equal "10", result["int_test"]
      assert_equal "2010-04-04", result["date_test"]
      assert_equal "val1", result["enum_test"]
    end

    test "returns nil for a NULL value" do
      assert_equal NilClass, @test_result['null_test'].class
      assert_nil @test_result['null_test']
    end

    test "returns String for a BIT(64) value" do
      assert_equal String, @test_result['bit_test'].class
      assert_equal "\000\000\000\000\000\000\000\005", @test_result['bit_test']
    end

    test "returns String for a BIT(1) value" do
      assert_equal String, @test_result['single_bit_test'].class
      assert_equal "\001", @test_result['single_bit_test']
    end

    test "returns Fixnum for a TINYINT value" do
      assert_includes [Fixnum, Bignum], @test_result['tiny_int_test'].class
      assert_equal 1, @test_result['tiny_int_test']
    end

    test "returns TrueClass or FalseClass for a TINYINT value if :cast_booleans is enabled" do
      @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES (1)'
      id1 = @client.last_id
      @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES (0)'
      id2 = @client.last_id
      @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES (-1)'
      id3 = @client.last_id

      result1 = @client.query 'SELECT bool_cast_test FROM mysql2_test WHERE bool_cast_test = 1 LIMIT 1', :cast_booleans => true
      result2 = @client.query 'SELECT bool_cast_test FROM mysql2_test WHERE bool_cast_test = 0 LIMIT 1', :cast_booleans => true
      result3 = @client.query 'SELECT bool_cast_test FROM mysql2_test WHERE bool_cast_test = -1 LIMIT 1', :cast_booleans => true
      assert result1.first['bool_cast_test'] == true
      assert result2.first['bool_cast_test'] == false
      assert result3.first['bool_cast_test'] == true

      @client.query "DELETE from mysql2_test WHERE id IN(#{id1},#{id2},#{id3})"
    end

    test "returns TrueClass or FalseClass for a BIT(1) value if :cast_booleans is enabled" do
      @client.query 'INSERT INTO mysql2_test (single_bit_test) VALUES (1)'
      id1 = @client.last_id
      @client.query 'INSERT INTO mysql2_test (single_bit_test) VALUES (0)'
      id2 = @client.last_id

      result1 = @client.query "SELECT single_bit_test FROM mysql2_test WHERE id = #{id1}", :cast_booleans => true
      result2 = @client.query "SELECT single_bit_test FROM mysql2_test WHERE id = #{id2}", :cast_booleans => true
      assert result1.first['single_bit_test'] == true
      assert result2.first['single_bit_test'] == false

      @client.query "DELETE from mysql2_test WHERE id IN(#{id1},#{id2})"
    end

    test "returns Fixnum for a SMALLINT value" do
      assert_includes [Fixnum, Bignum], @test_result['small_int_test'].class
      assert_equal 10, @test_result['small_int_test']
    end

    test "returns Fixnum for a MEDIUMINT value" do
      assert_includes [Fixnum, Bignum], @test_result['medium_int_test'].class
      assert_equal 10, @test_result['medium_int_test']
    end

    test "returns Fixnum for an INT value" do
      assert_includes [Fixnum, Bignum], @test_result['int_test'].class
      assert_equal 10, @test_result['int_test']
    end

    test "returns Fixnum for a BIGINT value" do
      assert_includes [Fixnum, Bignum], @test_result['big_int_test'].class
      assert_equal 10, @test_result['big_int_test']
    end

    test "returns Fixnum for a YEAR value" do
      assert_includes [Fixnum, Bignum], @test_result['year_test'].class
      assert_equal 2009, @test_result['year_test']
    end

    test "returns BigDecimal for a DECIMAL value" do
      assert_equal BigDecimal, @test_result['decimal_test'].class
      assert_equal 10.3, @test_result['decimal_test']
    end

    test "returns Float for a FLOAT value" do
      assert_equal Float, @test_result['float_test'].class
      assert_equal 10.3, @test_result['float_test']
    end

    test "returns Float for a DOUBLE value" do
      assert_equal Float, @test_result['double_test'].class
      assert_equal 10.3,@test_result['double_test']
    end

    test "returns Time for a DATETIME value when within the supported range" do
      assert_equal Time, @test_result['date_time_test'].class
      assert_equal '2010-04-04 11:44:00', @test_result['date_time_test'].strftime("%Y-%m-%d %H:%M:%S")
    end

    if 1.size == 4 # 32bit
      unless RUBY_VERSION =~ /1.8/
        klass = Time
      else
        klass = DateTime
      end

      test "returns DateTime when timestamp is < 1901-12-13 20:45:52" do
                                      # 1901-12-13T20:45:52 is the min for 32bit Ruby 1.8
        r = @client.query("SELECT CAST('1901-12-13 20:45:51' AS DATETIME) as test")
        assert_equal klass, r.first['test'].class
      end

      test "returns DateTime when timestamp is > 2038-01-19T03:14:07" do
                                      # 2038-01-19T03:14:07 is the max for 32bit Ruby 1.8
        r = @client.query("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test")
        assert_equal klass, r.first['test'].class
      end
    elsif 1.size == 8 # 64bit
      unless RUBY_VERSION =~ /1.8/
        test "returns Time when timestamp is < 1901-12-13 20:45:52" do
          r = @client.query("SELECT CAST('1901-12-13 20:45:51' AS DATETIME) as test")
          assert_equal Time, r.first['test'].class
        end

        test "returns Time when timestamp is > 2038-01-19T03:14:07" do
          r = @client.query("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test")
          assert_equal Time, r.first['test'].class
        end
      else
        test "returns Time when timestamp is > 0138-12-31 11:59:59" do
          r = @client.query("SELECT CAST('0139-1-1 00:00:00' AS DATETIME) as test")
          assert_equal Time, r.first['test'].class
        end

        test "returns DateTime when timestamp is < 0139-1-1T00:00:00" do
          r = @client.query("SELECT CAST('0138-12-31 11:59:59' AS DATETIME) as test")
          assert_equal DateTime, r.first['test'].class
        end

        test "returns Time when timestamp is > 2038-01-19T03:14:07" do
          r = @client.query("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test")
          assert_equal Time, r.first['test'].class
        end
      end
    end

    test "returns Time for a TIMESTAMP value when within the supported range" do
      assert_equal Time, @test_result['timestamp_test'].class
      assert_equal '2010-04-04 11:44:00', @test_result['timestamp_test'].strftime("%Y-%m-%d %H:%M:%S")
    end

    test "returns Time for a TIME value" do
      assert_equal Time, @test_result['time_test'].class
      assert_equal '2000-01-01 11:44:00', @test_result['time_test'].strftime("%Y-%m-%d %H:%M:%S")
    end

    test "returns Date for a DATE value" do
      assert_equal Date, @test_result['date_test'].class
      assert_equal '2010-04-04', @test_result['date_test'].strftime("%Y-%m-%d")
    end

    test "returns String for an ENUM value" do
      assert_equal String, @test_result['enum_test'].class
      assert_equal 'val1', @test_result['enum_test']
    end

    if defined? Encoding
      context "string encoding for ENUM values" do
        test "defaults to the connection's encoding if Encoding.default_internal is nil" do
          Encoding.default_internal = nil
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.find('utf-8'), result['enum_test'].encoding

          client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
          client2.query "USE test"
          result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.find('us-ascii'), result['enum_test'].encoding
          client2.close
        end

        test "uses Encoding.default_internal" do
          Encoding.default_internal = Encoding.find('utf-8')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.default_internal, result['enum_test'].encoding
          Encoding.default_internal = Encoding.find('us-ascii')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.default_internal, result['enum_test'].encoding
        end
      end
    end

    test "returns String for a SET value" do
      assert_equal String, @test_result['set_test'].class
      assert_equal 'val1,val2', @test_result['set_test']
    end

    if defined? Encoding
      context "string encoding for SET values" do
        test "defaults to the connection's encoding if Encoding.default_internal is nil" do
          Encoding.default_internal = nil
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.find('utf-8'), result['set_test'].encoding

          client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
          client2.query "USE test"
          result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.find('us-ascii'), result['set_test'].encoding
          client2.close
        end

        test "uses Encoding.default_internal" do
          Encoding.default_internal = Encoding.find('utf-8')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.default_internal, result['set_test'].encoding
          Encoding.default_internal = Encoding.find('us-ascii')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.default_internal, result['set_test'].encoding
        end
      end
    end

    test "returns String for a BINARY value" do
      assert_equal String, @test_result['binary_test'].class
      assert_equal "test#{"\000"*6}", @test_result['binary_test']
    end

    if defined? Encoding
      context "string encoding for BINARY values" do
        test "defaults to binary if Encoding.default_internal is nil" do
          Encoding.default_internal = nil
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.find('binary'), result['binary_test'].encoding
        end

        test "doesn't use Encoding.default_internal" do
          Encoding.default_internal = Encoding.find('utf-8')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.find('binary'), result['binary_test'].encoding
          Encoding.default_internal = Encoding.find('us-ascii')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          assert_equal Encoding.find('binary'), result['binary_test'].encoding
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
      test "returns a String for #{type}" do
        assert_equal String, @test_result[field].class
        assert_equal "test", @test_result[field]
      end

      if defined? Encoding
        context "string encoding for #{type} values" do
          if ['VARBINARY', 'TINYBLOB', 'BLOB', 'MEDIUMBLOB', 'LONGBLOB'].include?(type)
            test "defaults to binary if Encoding.default_internal is nil" do
              Encoding.default_internal = nil
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              assert_equal Encoding.find('binary'), result['binary_test'].encoding
            end

            test "doesn't use Encoding.default_internal" do
              Encoding.default_internal = Encoding.find('utf-8')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              assert_equal Encoding.find('binary'), result['binary_test'].encoding
              Encoding.default_internal = Encoding.find('us-ascii')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              assert_equal Encoding.find('binary'), result['binary_test'].encoding
            end
          else
            test "defaults to utf-8 if Encoding.default_internal is nil" do
              Encoding.default_internal = nil
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              assert_equal Encoding.find('utf-8'), result[field].encoding

              client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
              client2.query "USE test"
              result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              assert_equal Encoding.find('us-ascii'), result[field].encoding
              client2.close
            end

            test "uses Encoding.default_internal" do
              Encoding.default_internal = Encoding.find('utf-8')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              assert_equal Encoding.default_internal, result[field].encoding
              Encoding.default_internal = Encoding.find('us-ascii')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              assert_equal Encoding.default_internal, result[field].encoding
            end
          end
        end
      end
    end
  end
end
