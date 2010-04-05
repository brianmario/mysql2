# encoding: UTF-8
require File.expand_path(File.dirname(__FILE__) + '/../spec_helper.rb')

describe Mysql2::Client do
  before(:each) do
    @client = Mysql2::Client.new
  end

  it "should respond to #query" do
    @client.should respond_to :query
  end

  it "should respond to #escape" do
    @client.should respond_to :escape
  end

  it "#escape should return a new SQL-escape version of the passed string" do
    @client.escape("abc'def\"ghi\0jkl%mno").should eql("abc\\'def\\\"ghi\\0jkl%mno")
  end

  it "#escape should return the passed string if nothing was escaped" do
    str = "plain"
    @client.escape(str).object_id.should eql(str.object_id)
  end

  it "should respond to #info" do
    @client.should respond_to :info
  end

  it "#info should return a hash containing the client version ID and String" do
    info = @client.info
    info.class.should eql(Hash)
    info.should have_key(:id)
    info[:id].class.should eql(Fixnum)
    info.should have_key(:version)
    info[:version].class.should eql(String)
  end

  it "should respond to #server_info" do
    @client.should respond_to :server_info
  end

  it "#server_info should return a hash containing the client version ID and String" do
    server_info = @client.server_info
    server_info.class.should eql(Hash)
    server_info.should have_key(:id)
    server_info[:id].class.should eql(Fixnum)
    server_info.should have_key(:version)
    server_info[:version].class.should eql(String)
  end

  it "should respond to #socket" do
    @client.should respond_to :socket
  end

  it "#socket should return a Fixnum (file descriptor from C)" do
    @client.socket.class.should eql(Fixnum)
    @client.socket.should_not eql(0)
  end
end