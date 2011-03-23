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
    it "#message encoding should match the connection's encoding" do
      @error.message.encoding.should eql(@client.encoding)
    end

    it "#error encoding should match the connection's encoding" do
      @error.error.encoding.should eql(@client.encoding)
    end

    it "#sql_state encoding should match the connection's encoding" do
      @error.sql_state.encoding.should eql(@client.encoding)
    end
  end
end
