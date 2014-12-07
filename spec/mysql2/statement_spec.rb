# encoding: UTF-8
require './spec/spec_helper.rb'

describe Mysql2::Statement do
  before :each do
    @client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "utf8"))
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
    statement.execute.should_not == nil
  end

  it "should raise an exception without a block" do
    statement = @client.prepare 'SELECT 1'
    statement.execute
    lambda { statement.each }.should raise_error
  end

  it "should tell us the result count" do
    statement = @client.prepare 'SELECT 1'
    result = statement.execute
    result.count.should == 1
  end

  it "should let us iterate over results" do
    statement = @client.prepare 'SELECT 1'
    result = statement.execute
    rows = []
    result.each {|r| rows << r}
    rows.should == [{"1"=>1}]
  end

  it "should keep its result after other query" do
    @client.query 'USE test'
    @client.query 'CREATE TABLE IF NOT EXISTS mysql2_stmt_q(a int)'
    @client.query 'INSERT INTO mysql2_stmt_q (a) VALUES (1), (2)'
    stmt = @client.prepare('SELECT a FROM mysql2_stmt_q WHERE a = ?')
    result1 = stmt.execute(1)
    result2 = stmt.execute(2)
    result2.first.should == {"a"=>2}
    result1.first.should == {"a"=>1}
    @client.query 'DROP TABLE IF EXISTS mysql2_stmt_q'
  end

  it "should select dates" do
    statement = @client.prepare 'SELECT NOW()'
    result = statement.execute
    result.first.first[1].should be_kind_of Time
  end

  it "should tell us about the fields" do
    statement = @client.prepare 'SELECT 1 as foo, 2'
    statement.execute
    list = statement.fields
    list.length.should == 2
    list.first.should == 'foo'
    list[1].should == '2'
  end

  context "utf8_db" do
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
      result = stmt.execute

      result.to_a.should == [{"整数"=>1, "文字列"=>"イチ"}, {"整数"=>2, "文字列"=>"弐"}, {"整数"=>3, "文字列"=>"さん"}]
    end

    it "should be able to retrieve utf8 param query correctly" do
      stmt = @client.prepare 'SELECT 整数 FROM テーブル WHERE 文字列 = ?'
      stmt.param_count.should == 1

      result = stmt.execute 'イチ'

      result.to_a.should == [{"整数"=>1}]
    end

    it "should be able to retrieve query with param in different encoding correctly" do
      stmt = @client.prepare 'SELECT 整数 FROM テーブル WHERE 文字列 = ?'
      stmt.param_count.should == 1

      param = 'イチ'.encode("EUC-JP")
      result = stmt.execute param

      result.to_a.should == [{"整数"=>1}]
    end

  end

  context "streaming result" do
    it "should be able to stream query result" do
      n = 1
      stmt = @client.prepare("SELECT 1 UNION SELECT 2")

      @client.query_options.merge!({:stream => true, :cache_rows => false, :as => :array})

      stmt.execute.each do |r|
        case n
        when 1
          r.should == [1]
        when 2
          r.should == [2]
        else
          violated "returned more than two rows"
        end
        n += 1
      end
    end
  end

  context "row data type mapping" do
    before(:each) do
      @client.query "USE test"
      @test_result = @client.prepare("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").execute.first
    end

    it "should return nil values for NULL and strings for everything else when :cast is false" do
      result = @client.query('SELECT null_test, tiny_int_test, bool_cast_test, int_test, date_test, enum_test FROM mysql2_test WHERE bool_cast_test = 1 LIMIT 1', :cast => false).first
      result["null_test"].should be_nil
      result["tiny_int_test"].should  == "1"
      result["bool_cast_test"].should == "1"
      result["int_test"].should       == "10"
      result["date_test"].should      == "2010-04-04"
      result["enum_test"].should      == "val1"
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
      @test_result['float_test'].should be_within(1e-5).of(10.3)
    end

    it "should return Float for a DOUBLE value" do
      @test_result['double_test'].class.should eql(Float)
      @test_result['double_test'].should be_within(1e-5).of(10.3)
    end

    it "should return Time for a DATETIME value when within the supported range" do
      @test_result['date_time_test'].class.should eql(Time)
      @test_result['date_time_test'].strftime("%Y-%m-%d %H:%M:%S").should eql('2010-04-04 11:44:00')
    end

    if 1.size == 4 # 32bit
      if RUBY_VERSION =~ /1.8/
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

    if defined? Encoding
      context "string encoding for ENUM values" do
        it "should default to the connection's encoding if Encoding.default_internal is nil" do
          Encoding.default_internal = nil
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['enum_test'].encoding.should eql(Encoding.find('utf-8'))

          client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "ascii"))
          client2.query "USE test"
          result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['enum_test'].encoding.should eql(Encoding.find('us-ascii'))
        end

        it "should use Encoding.default_internal" do
          Encoding.default_internal = Encoding.find('utf-8')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['enum_test'].encoding.should eql(Encoding.default_internal)
          Encoding.default_internal = Encoding.find('us-ascii')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['enum_test'].encoding.should eql(Encoding.default_internal)
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
          Encoding.default_internal = nil
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['set_test'].encoding.should eql(Encoding.find('utf-8'))

          client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "ascii"))
          client2.query "USE test"
          result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['set_test'].encoding.should eql(Encoding.find('us-ascii'))
        end

        it "should use Encoding.default_internal" do
          Encoding.default_internal = Encoding.find('utf-8')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['set_test'].encoding.should eql(Encoding.default_internal)
          Encoding.default_internal = Encoding.find('us-ascii')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['set_test'].encoding.should eql(Encoding.default_internal)
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
          Encoding.default_internal = nil
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['binary_test'].encoding.should eql(Encoding.find('binary'))
        end

        it "should not use Encoding.default_internal" do
          Encoding.default_internal = Encoding.find('utf-8')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['binary_test'].encoding.should eql(Encoding.find('binary'))
          Encoding.default_internal = Encoding.find('us-ascii')
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          result['binary_test'].encoding.should eql(Encoding.find('binary'))
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
              Encoding.default_internal = nil
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              result['binary_test'].encoding.should eql(Encoding.find('binary'))
            end

            it "should not use Encoding.default_internal" do
              Encoding.default_internal = Encoding.find('utf-8')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              result['binary_test'].encoding.should eql(Encoding.find('binary'))
              Encoding.default_internal = Encoding.find('us-ascii')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              result['binary_test'].encoding.should eql(Encoding.find('binary'))
            end
          else
            it "should default to utf-8 if Encoding.default_internal is nil" do
              Encoding.default_internal = nil
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              result[field].encoding.should eql(Encoding.find('utf-8'))

              client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "ascii"))
              client2.query "USE test"
              result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              result[field].encoding.should eql(Encoding.find('us-ascii'))
            end

            it "should use Encoding.default_internal" do
              Encoding.default_internal = Encoding.find('utf-8')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              result[field].encoding.should eql(Encoding.default_internal)
              Encoding.default_internal = Encoding.find('us-ascii')
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              result[field].encoding.should eql(Encoding.default_internal)
            end
          end
        end
      end
    end
  end

end
