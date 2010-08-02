# encoding: UTF-8
require 'spec_helper'
require 'rubygems'
require 'active_record'
require 'active_record/connection_adapters/mysql2_adapter'

class Mysql2Test2 < ActiveRecord::Base
  set_table_name "mysql2_test2"
end

describe ActiveRecord::ConnectionAdapters::Mysql2Adapter do
  it "should be able to connect" do
    lambda {
      ActiveRecord::Base.establish_connection(:adapter => 'mysql2')
    }.should_not raise_error(Mysql2::Error)
  end

  context "once connected" do
    before(:each) do
      @connection = ActiveRecord::Base.connection
    end

    it "should be able to execute a raw query" do
      @connection.execute("SELECT 1 as one").first.first.should eql(1)
      @connection.execute("SELECT NOW() as n").first.first.class.should eql(Time)
    end
  end

  context "columns" do
    before(:all) do
      ActiveRecord::Base.default_timezone = 'Pacific Time (US & Canada)'
      ActiveRecord::Base.time_zone_aware_attributes = true
      ActiveRecord::Base.establish_connection(:adapter => 'mysql2', :database => 'test')
      Mysql2Test2.connection.execute %[
        CREATE TABLE IF NOT EXISTS mysql2_test2 (
          `id` mediumint(9) NOT NULL AUTO_INCREMENT,
          `null_test` varchar(10) DEFAULT NULL,
          `bit_test` bit(64) NOT NULL DEFAULT b'1',
          `boolean_test` tinyint(1) DEFAULT 0,
          `tiny_int_test` tinyint(4) NOT NULL DEFAULT '1',
          `small_int_test` smallint(6) NOT NULL DEFAULT '1',
          `medium_int_test` mediumint(9) NOT NULL DEFAULT '1',
          `int_test` int(11) NOT NULL DEFAULT '1',
          `big_int_test` bigint(20) NOT NULL DEFAULT '1',
          `float_test` float(10,3) NOT NULL DEFAULT '1.000',
          `double_test` double(10,3) NOT NULL DEFAULT '1.000',
          `decimal_test` decimal(10,3) NOT NULL DEFAULT '1.000',
          `date_test` date NOT NULL DEFAULT '2010-01-01',
          `date_time_test` datetime NOT NULL DEFAULT '2010-01-01 00:00:00',
          `timestamp_test` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
          `time_test` time NOT NULL DEFAULT '00:00:00',
          `year_test` year(4) NOT NULL DEFAULT '2010',
          `char_test` char(10) NOT NULL DEFAULT 'abcdefghij',
          `varchar_test` varchar(10) NOT NULL DEFAULT 'abcdefghij',
          `binary_test` binary(10) NOT NULL DEFAULT 'abcdefghij',
          `varbinary_test` varbinary(10) NOT NULL DEFAULT 'abcdefghij',
          `tiny_blob_test` tinyblob NOT NULL,
          `tiny_text_test` tinytext,
          `blob_test` blob,
          `text_test` text,
          `medium_blob_test` mediumblob,
          `medium_text_test` mediumtext,
          `long_blob_test` longblob,
          `long_text_test` longtext,
          `enum_test` enum('val1','val2') NOT NULL DEFAULT 'val1',
          `set_test` set('val1','val2') NOT NULL DEFAULT 'val1,val2',
          PRIMARY KEY (`id`)
        )
      ]
      Mysql2Test2.connection.execute "INSERT INTO mysql2_test2 (null_test) VALUES (NULL)"
      @test_result = Mysql2Test2.connection.execute("SELECT * FROM mysql2_test2 ORDER BY id DESC LIMIT 1").first
    end

    after(:all) do
      Mysql2Test2.connection.execute("DELETE FROM mysql2_test WHERE id=#{@test_result.first}")
    end

    it "default value should be cast to the expected type of the field" do
      test = Mysql2Test2.new
      test.null_test.should be_nil
      test.bit_test.should eql("b'1'")
      test.boolean_test.should eql(false)
      test.tiny_int_test.should eql(1)
      test.small_int_test.should eql(1)
      test.medium_int_test.should eql(1)
      test.int_test.should eql(1)
      test.big_int_test.should eql(1)
      test.float_test.should eql('1.0000'.to_f)
      test.double_test.should eql('1.0000'.to_f)
      test.decimal_test.should eql(BigDecimal.new('1.0000'))
      test.date_test.should eql(Date.parse('2010-01-01'))
      test.date_time_test.should eql(DateTime.parse('2010-01-01 00:00:00'))
      test.timestamp_test.should be_nil
      test.time_test.class.should eql(DateTime)
      test.year_test.should eql(2010)
      test.char_test.should eql('abcdefghij')
      test.varchar_test.should eql('abcdefghij')
      test.binary_test.should eql('abcdefghij')
      test.varbinary_test.should eql('abcdefghij')
      test.tiny_blob_test.should eql("")
      test.tiny_text_test.should be_nil
      test.blob_test.should be_nil
      test.text_test.should be_nil
      test.medium_blob_test.should be_nil
      test.medium_text_test.should be_nil
      test.long_blob_test.should be_nil
      test.long_text_test.should be_nil
      test.long_blob_test.should be_nil
      test.enum_test.should eql('val1')
      test.set_test.should eql('val1,val2')
      test.save
    end

    it "should have correct values when pulled from a db record" do
      test = Mysql2Test2.last
      test.null_test.should be_nil
      test.bit_test.class.should eql(String)
      test.boolean_test.should eql(false)
      test.tiny_int_test.should eql(1)
      test.small_int_test.should eql(1)
      test.medium_int_test.should eql(1)
      test.int_test.should eql(1)
      test.big_int_test.should eql(1)
      test.float_test.should eql('1.0000'.to_f)
      test.double_test.should eql('1.0000'.to_f)
      test.decimal_test.should eql(BigDecimal.new('1.0000'))
      test.date_test.should eql(Date.parse('2010-01-01'))
      test.date_time_test.should eql(Time.utc(2010,1,1,0,0,0))
      test.timestamp_test.class.should eql(ActiveSupport::TimeWithZone)
      test.time_test.class.should eql(Time)
      test.year_test.should eql(2010)
      test.char_test.should eql('abcdefghij')
      test.varchar_test.should eql('abcdefghij')
      test.binary_test.should eql('abcdefghij')
      test.varbinary_test.should eql('abcdefghij')
      test.tiny_blob_test.should eql("")
      test.tiny_text_test.should be_nil
      test.blob_test.should be_nil
      test.text_test.should be_nil
      test.medium_blob_test.should be_nil
      test.medium_text_test.should be_nil
      test.long_blob_test.should be_nil
      test.long_text_test.should be_nil
      test.long_blob_test.should be_nil
      test.enum_test.should eql('val1')
      test.set_test.should eql('val1,val2')
    end
  end
end
