# encoding: UTF-8
require File.expand_path(File.dirname(__FILE__) + '/../spec_helper.rb')

describe Mysql2::Client do
  before(:each) do
    @client = Mysql2::Client.new
  end

  it "should be able to connect via SSL options" do
    pending("DON'T WORRY, THIS TEST PASSES :) - but is machine-specific. You need to have MySQL running with SSL configured and enabled. Then update the paths in this test to your needs and remove the pending state.")
    ssl_client = nil
    lambda {
      ssl_client = Mysql2::Client.new(
        :sslkey => '/path/to/client-key.pem',
        :sslcert => '/path/to/client-cert.pem',
        :sslca => '/path/to/ca-cert.pem',
        :sslcapath => '/path/to/newcerts/',
        :sslcipher => 'DHE-RSA-AES256-SHA'
      )
    }.should_not raise_error(Mysql2::Error)

    results = ssl_client.query("SHOW STATUS WHERE Variable_name = \"Ssl_version\" OR Variable_name = \"Ssl_cipher\"").to_a
    results[0]['Variable_name'].should eql('Ssl_cipher')
    results[0]['Value'].should_not be_nil
    results[0]['Value'].class.should eql(String)

    results[1]['Variable_name'].should eql('Ssl_version')
    results[1]['Value'].should_not be_nil
    results[1]['Value'].class.should eql(String)
  end

  it "should respond to #close" do
    @client.should respond_to :close
  end

  it "should be able to close properly" do
    @client.close.should be_nil
  end

  it "should raise an exception when closed twice" do
    @client.close.should be_nil
    lambda {
      @client.close
    }.should raise_error(Mysql2::Error)
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

  if RUBY_VERSION =~ /^1.9/
    context "strings returned by #info" do
      it "should default to utf-8 if Encoding.default_internal is nil" do
        Encoding.default_internal = nil
        @client.info[:version].encoding.should eql(Encoding.find('utf-8'))
      end

      it "should use Encoding.default_internal" do
        Encoding.default_internal = Encoding.find('utf-8')
        @client.info[:version].encoding.should eql(Encoding.default_internal)
        Encoding.default_internal = Encoding.find('us-ascii')
        @client.info[:version].encoding.should eql(Encoding.default_internal)
      end
    end
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

  if RUBY_VERSION =~ /^1.9/
    context "strings returned by #server_info" do
      it "should default to utf-8 if Encoding.default_internal is nil" do
        Encoding.default_internal = nil
        @client.server_info[:version].encoding.should eql(Encoding.find('utf-8'))
      end

      it "should use Encoding.default_internal" do
        Encoding.default_internal = Encoding.find('utf-8')
        @client.server_info[:version].encoding.should eql(Encoding.default_internal)
        Encoding.default_internal = Encoding.find('us-ascii')
        @client.server_info[:version].encoding.should eql(Encoding.default_internal)
      end
    end
  end

  it "should respond to #socket" do
    @client.should respond_to :socket
  end

  it "#socket should return a Fixnum (file descriptor from C)" do
    @client.socket.class.should eql(Fixnum)
    @client.socket.should_not eql(0)
  end

  it "should raise a Mysql2::Error exception upon connection failure" do
    lambda {
      bad_client = Mysql2::Client.new :host => "dfjhdi9wrhw", :username => 'asdfasdf8d2h'
    }.should raise_error(Mysql2::Error)

    lambda {
      good_client = Mysql2::Client.new
    }.should_not raise_error(Mysql2::Error)
  end

  it "evented async queries should be supported" do
    # should immediately return nil
    @client.query("SELECT sleep(0.1)", :async => true).should eql(nil)

    io_wrapper = IO.for_fd(@client.socket)
    loops = 0
    loop do
      if IO.select([io_wrapper], nil, nil, 0.05)
        break
      else
        loops += 1
      end
    end

    # make sure we waited some period of time
    (loops >= 1).should be_true

    result = @client.async_result
    result.class.should eql(Mysql2::Result)
  end

  context 'write operations api' do
    before(:each) do
      @client.query "USE test"
      @client.query "CREATE TABLE lastIdTest (`id` int(11) NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"
    end

    after(:each) do
      @client.query "DROP TABLE lastIdTest"
    end

    it "should respond to #last_id" do
      @client.should respond_to(:last_id)
    end

    it "#last_id should return a Fixnum, the from the last INSERT/UPDATE" do
      @client.last_id.should eql(0)
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      @client.last_id.should eql(1)
    end

    it "should respond to #last_id" do
      @client.should respond_to(:last_id)
    end

    it "#last_id should return a Fixnum, the from the last INSERT/UPDATE" do
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      @client.affected_rows.should eql(1)
      @client.query "UPDATE lastIdTest SET blah=4321 WHERE id=1"
      @client.affected_rows.should eql(1)
    end
  end
end