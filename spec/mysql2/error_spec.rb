# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Error do
  before(:each) do
    @client = Mysql2::Client.new :encoding => "utf8"
    begin
      @client.query("HAHAHA")
    rescue Mysql2::Error => e
      @error = e
    end

    @client2 = Mysql2::Client.new :encoding => "big5"
    begin
      @client2.query("HAHAHA")
    rescue Mysql2::Error => e
      @error2 = e
    end
  end

  it "should respond to #error_number" do
    @error.should respond_to(:error_number)
  end

  it "should respond to #sql_state" do
    @error.should respond_to(:sql_state)
  end

  # Mysql gem compatibility
  it "should alias #error_number to #errno" do
    @error.should respond_to(:errno)
  end

  it "should alias #message to #error" do
    @error.should respond_to(:error)
  end

  if RUBY_VERSION =~ /1.9/
    it "#message encoding should match the connection's encoding, or Encoding.default_internal if set" do
      if Encoding.default_internal.nil?
        @error.message.encoding.should eql(@client.encoding)
        @error2.message.encoding.should eql(@client2.encoding)
      else
        @error.message.encoding.should eql(Encoding.default_internal)
        @error2.message.encoding.should eql(Encoding.default_internal)
      end
    end

    it "#error encoding should match the connection's encoding, or Encoding.default_internal if set" do
      if Encoding.default_internal.nil?
        @error.error.encoding.should eql(@client.encoding)
        @error2.error.encoding.should eql(@client2.encoding)
      else
        @error.error.encoding.should eql(Encoding.default_internal)
        @error2.error.encoding.should eql(Encoding.default_internal)
      end
    end

    it "#sql_state encoding should match the connection's encoding, or Encoding.default_internal if set" do
      if Encoding.default_internal.nil?
        @error.sql_state.encoding.should eql(@client.encoding)
        @error2.sql_state.encoding.should eql(@client2.encoding)
      else
        @error.sql_state.encoding.should eql(Encoding.default_internal)
        @error2.sql_state.encoding.should eql(Encoding.default_internal)
      end
    end
  end
end
