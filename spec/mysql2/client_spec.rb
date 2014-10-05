# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Client do
  context "using defaults file" do
    let(:cnf_file) { File.expand_path('../../my.cnf', __FILE__) }

    it "should not raise an exception for valid defaults group" do
      lambda {
        opts = DatabaseCredentials['root'].merge(:default_file => cnf_file, :default_group => "test")
        @client = Mysql2::Client.new(opts)
      }.should_not raise_error(Mysql2::Error)
    end

    it "should not raise an exception without default group" do
      lambda {
        @client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:default_file => cnf_file))
      }.should_not raise_error(Mysql2::Error)
    end
  end

  it "should raise an exception upon connection failure" do
    lambda {
      # The odd local host IP address forces the mysql client library to
      # use a TCP socket rather than a domain socket.
      Mysql2::Client.new DatabaseCredentials['root'].merge('host' => '127.0.0.2', 'port' => 999999)
    }.should raise_error(Mysql2::Error)
  end

  if defined? Encoding
    it "should raise an exception on create for invalid encodings" do
      lambda {
        Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "fake"))
      }.should raise_error(Mysql2::Error)
    end

    it "should not raise an exception on create for a valid encoding" do
      lambda {
        Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "utf8"))
      }.should_not raise_error(Mysql2::Error)

      lambda {
        Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "big5"))
      }.should_not raise_error(Mysql2::Error)
    end
  end

  it "should accept connect flags and pass them to #connect" do
    klient = Class.new(Mysql2::Client) do
      attr_reader :connect_args
      def connect *args
        @connect_args ||= []
        @connect_args << args
      end
    end
    client = klient.new :flags => Mysql2::Client::FOUND_ROWS
    (client.connect_args.last[6] & Mysql2::Client::FOUND_ROWS).should be_true
  end

  it "should default flags to (REMEMBER_OPTIONS, LONG_PASSWORD, LONG_FLAG, TRANSACTIONS, PROTOCOL_41, SECURE_CONNECTION)" do
    klient = Class.new(Mysql2::Client) do
      attr_reader :connect_args
      def connect *args
        @connect_args ||= []
        @connect_args << args
      end
    end
    client = klient.new
    (client.connect_args.last[6] & (Mysql2::Client::REMEMBER_OPTIONS |
                                     Mysql2::Client::LONG_PASSWORD |
                                     Mysql2::Client::LONG_FLAG |
                                     Mysql2::Client::TRANSACTIONS |
                                     Mysql2::Client::PROTOCOL_41 |
                                     Mysql2::Client::SECURE_CONNECTION)).should be_true
  end

  it "should execute init command" do
    options = DatabaseCredentials['root'].dup
    options[:init_command] = "SET @something = 'setting_value';"
    client = Mysql2::Client.new(options)
    result = client.query("SELECT @something;")
    result.first['@something'].should eq('setting_value')
  end

  it "should send init_command after reconnect" do
    options = DatabaseCredentials['root'].dup
    options[:init_command] = "SET @something = 'setting_value';"
    options[:reconnect] = true
    client = Mysql2::Client.new(options)

    result = client.query("SELECT @something;")
    result.first['@something'].should eq('setting_value')

    # get the current connection id
    result = client.query("SELECT CONNECTION_ID()")
    first_conn_id = result.first['CONNECTION_ID()']

    # break the current connection
    begin
      client.query("KILL #{first_conn_id}")
    rescue Mysql2::Error
    end

    client.ping # reconnect now

    # get the new connection id
    result = client.query("SELECT CONNECTION_ID()")
    second_conn_id = result.first['CONNECTION_ID()']

    # confirm reconnect by checking the new connection id
    first_conn_id.should_not == second_conn_id

    # At last, check that the init command executed
    result = client.query("SELECT @something;")
    result.first['@something'].should eq('setting_value')
  end

  it "should have a global default_query_options hash" do
    Mysql2::Client.should respond_to(:default_query_options)
  end

  it "should be able to connect via SSL options" do
    ssl = @client.query "SHOW VARIABLES LIKE 'have_ssl'"
    ssl_uncompiled = ssl.any? {|x| x['Value'] == 'OFF'}
    pending("DON'T WORRY, THIS TEST PASSES - but SSL is not compiled into your MySQL daemon.") if ssl_uncompiled
    ssl_disabled = ssl.any? {|x| x['Value'] == 'DISABLED'}
    pending("DON'T WORRY, THIS TEST PASSES - but SSL is not enabled in your MySQL daemon.") if ssl_disabled

    # You may need to adjust the lines below to match your SSL certificate paths
    ssl_client = nil
    lambda {
      ssl_client = Mysql2::Client.new(
        :sslkey    => '/etc/mysql/client-key.pem',
        :sslcert   => '/etc/mysql/client-cert.pem',
        :sslca     => '/etc/mysql/ca-cert.pem',
        :sslcapath => '/etc/mysql/',
        :sslcipher => 'DHE-RSA-AES256-SHA'
      )
    }.should_not raise_error(Mysql2::Error)

    results = ssl_client.query("SHOW STATUS WHERE Variable_name = \"Ssl_version\" OR Variable_name = \"Ssl_cipher\"").to_a
    results[0]['Variable_name'].should eql('Ssl_cipher')
    results[0]['Value'].should_not be_nil
    results[0]['Value'].should be_kind_of(String)
    results[0]['Value'].should_not be_empty

    results[1]['Variable_name'].should eql('Ssl_version')
    results[1]['Value'].should_not be_nil
    results[1]['Value'].should be_kind_of(String)
    results[1]['Value'].should_not be_empty

    ssl_client.close
  end

  it "should not leave dangling connections after garbage collection" do
    GC.start
    sleep 0.300 # Let GC do its work
    client = Mysql2::Client.new(DatabaseCredentials['root'])
    before_count = client.query("SHOW STATUS LIKE 'Threads_connected'").first['Value'].to_i

    10.times do
      Mysql2::Client.new(DatabaseCredentials['root']).query('SELECT 1')
    end
    after_count = client.query("SHOW STATUS LIKE 'Threads_connected'").first['Value'].to_i
    after_count.should == before_count + 10

    GC.start
    sleep 0.300 # Let GC do its work
    final_count = client.query("SHOW STATUS LIKE 'Threads_connected'").first['Value'].to_i
    final_count.should == before_count
  end

  if Process.respond_to?(:fork)
    it "should not close connections when running in a child process" do
      GC.start
      sleep 1 if defined? Rubinius # Let the rbx GC thread do its work
      client = Mysql2::Client.new(DatabaseCredentials['root'])

      fork do
        client.query('SELECT 1')
        client = nil
        GC.start
        sleep 1 if defined? Rubinius # Let the rbx GC thread do its work
      end

      Process.wait

      # this will throw an error if the underlying socket was shutdown by the
      # child's GC
      expect { client.query('SELECT 1') }.to_not raise_exception
    end
  end

  it "should be able to connect to database with numeric-only name" do
    lambda {
      creds = DatabaseCredentials['numericuser']
      @client.query "CREATE DATABASE IF NOT EXISTS `#{creds['database']}`"
      @client.query "GRANT ALL ON `#{creds['database']}`.* TO #{creds['username']}@`#{creds['host']}`"
      client = Mysql2::Client.new creds
      @client.query "DROP DATABASE IF EXISTS `#{creds['database']}`"
    }.should_not raise_error
  end

  it "should respond to #close" do
    @client.should respond_to(:close)
  end

  it "should be able to close properly" do
    @client.close.should be_nil
    lambda {
      @client.query "SELECT 1"
    }.should raise_error(Mysql2::Error)
  end

  it "should respond to #query" do
    @client.should respond_to(:query)
  end

  it "should respond to #warning_count" do
    @client.should respond_to(:warning_count)
  end

  context "#warning_count" do
    context "when no warnings" do
      it "should 0" do
        @client.query('select 1')
        @client.warning_count.should == 0
      end
    end
    context "when has a warnings" do
      it "should > 0" do
        # "the statement produces extra information that can be viewed by issuing a SHOW WARNINGS"
        # http://dev.mysql.com/doc/refman/5.0/en/explain-extended.html
        @client.query("explain extended select 1")
        @client.warning_count.should > 0
      end
    end
  end

  it "should respond to #query_info" do
    @client.should respond_to(:query_info)
  end

  context "#query_info" do
    context "when no info present" do
      it "should 0" do
        @client.query('select 1')
        @client.query_info.should be_empty
        @client.query_info_string.should be_nil
      end
    end
    context "when has some info" do
      it "should retrieve it" do
        @client.query "USE test"
        @client.query "CREATE TABLE IF NOT EXISTS infoTest (`id` int(11) NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"

        # http://dev.mysql.com/doc/refman/5.0/en/mysql-info.html says
        # # Note that mysql_info() returns a non-NULL value for INSERT ... VALUES only for the multiple-row form of the statement (that is, only if multiple value lists are specified).
        @client.query("INSERT INTO infoTest (blah) VALUES (1234),(4535)")

        @client.query_info.should  eql({:records => 2, :duplicates => 0, :warnings => 0})
        @client.query_info_string.should eq('Records: 2  Duplicates: 0  Warnings: 0')

        @client.query "DROP TABLE infoTest"
      end
    end
  end

  context ":local_infile" do
    before(:all) do
      @client_i = Mysql2::Client.new DatabaseCredentials['root'].merge(:local_infile => true)
      local = @client_i.query "SHOW VARIABLES LIKE 'local_infile'"
      local_enabled = local.any? {|x| x['Value'] == 'ON'}
      pending("DON'T WORRY, THIS TEST PASSES - but LOCAL INFILE is not enabled in your MySQL daemon.") unless local_enabled

      @client_i.query %[
        CREATE TABLE IF NOT EXISTS infileTest (
          id MEDIUMINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
          foo VARCHAR(10),
          bar MEDIUMTEXT
        )
      ]
    end

    after(:all) do
      @client_i.query "DROP TABLE infileTest"
    end

    it "should raise an error when local_infile is disabled" do
      client = Mysql2::Client.new DatabaseCredentials['root'].merge(:local_infile => false)
      lambda {
        client.query "LOAD DATA LOCAL INFILE 'spec/test_data' INTO TABLE infileTest"
      }.should raise_error(Mysql2::Error, %r{command is not allowed})
    end

    it "should raise an error when a non-existent file is loaded" do
      lambda {
        @client_i.query "LOAD DATA LOCAL INFILE 'this/file/is/not/here' INTO TABLE infileTest"
      }.should_not raise_error(Mysql2::Error, %r{file not found: this/file/is/not/here})
    end

    it "should LOAD DATA LOCAL INFILE" do
      @client_i.query "LOAD DATA LOCAL INFILE 'spec/test_data' INTO TABLE infileTest"
      info = @client_i.query_info
      info.should eql({:records => 1, :deleted => 0, :skipped => 0, :warnings => 0})

      result = @client_i.query "SELECT * FROM infileTest"
      result.first.should eql({'id' => 1, 'foo' => 'Hello', 'bar' => 'World'})
    end
  end

  it "should expect connect_timeout to be a positive integer" do
    lambda {
      Mysql2::Client.new(:connect_timeout => -1)
    }.should raise_error(Mysql2::Error)
  end

  it "should expect read_timeout to be a positive integer" do
    lambda {
      Mysql2::Client.new(:read_timeout => -1)
    }.should raise_error(Mysql2::Error)
  end

  it "should expect write_timeout to be a positive integer" do
    lambda {
      Mysql2::Client.new(:write_timeout => -1)
    }.should raise_error(Mysql2::Error)
  end

  context "#query" do
    it "should let you query again if iterating is finished when streaming" do
      @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false).each.to_a

      expect {
        @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false)
      }.to_not raise_exception(Mysql2::Error)
    end

    it "should not let you query again if iterating is not finished when streaming" do
      @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false).first

      expect {
        @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false)
      }.to raise_exception(Mysql2::Error)
    end

    it "should only accept strings as the query parameter" do
      lambda {
        @client.query ["SELECT 'not right'"]
      }.should raise_error(TypeError)
    end

    it "should not retain query options set on a query for subsequent queries, but should retain it in the result" do
      result = @client.query "SELECT 1", :something => :else
      @client.query_options[:something].should be_nil
      result.instance_variable_get('@query_options').should eql(@client.query_options.merge(:something => :else))
      @client.instance_variable_get('@current_query_options').should eql(@client.query_options.merge(:something => :else))

      result = @client.query "SELECT 1"
      result.instance_variable_get('@query_options').should eql(@client.query_options)
      @client.instance_variable_get('@current_query_options').should eql(@client.query_options)
    end

    it "should allow changing query options for subsequent queries" do
      @client.query_options.merge!(:something => :else)
      result = @client.query "SELECT 1"
      @client.query_options[:something].should eql(:else)
      result.instance_variable_get('@query_options')[:something].should eql(:else)

      # Clean up after this test
      @client.query_options.delete(:something)
      @client.query_options[:something].should be_nil
    end

    it "should return results as a hash by default" do
      @client.query("SELECT 1").first.class.should eql(Hash)
    end

    it "should be able to return results as an array" do
      @client.query("SELECT 1", :as => :array).first.class.should eql(Array)
      @client.query("SELECT 1").each(:as => :array)
    end

    it "should be able to return results with symbolized keys" do
      @client.query("SELECT 1", :symbolize_keys => true).first.keys[0].class.should eql(Symbol)
    end

    it "should require an open connection" do
      @client.close
      lambda {
        @client.query "SELECT 1"
      }.should raise_error(Mysql2::Error)
    end

    if RUBY_PLATFORM !~ /mingw|mswin/
      it "should not allow another query to be sent without fetching a result first" do
        @client.query("SELECT 1", :async => true)
        lambda {
          @client.query("SELECT 1")
        }.should raise_error(Mysql2::Error)
      end

      it "should describe the thread holding the active query" do
        thr = Thread.new { @client.query("SELECT 1", :async => true) }

        thr.join
        begin
          @client.query("SELECT 1")
        rescue Mysql2::Error => e
          message = e.message
        end
        re = Regexp.escape(thr.inspect)
        message.should match(Regexp.new(re))
      end

      it "should timeout if we wait longer than :read_timeout" do
        client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:read_timeout => 1))
        lambda {
          client.query("SELECT sleep(2)")
        }.should raise_error(Mysql2::Error)
      end

      if !defined? Rubinius
        # XXX this test is not deterministic (because Unix signal handling is not)
        # and may fail on a loaded system
        it "should run signal handlers while waiting for a response" do
          mark = {}
          trap(:USR1) { mark[:USR1] = Time.now }
          begin
            mark[:START] = Time.now
            pid = fork do
              sleep 1 # wait for client "SELECT sleep(2)" query to start
              Process.kill(:USR1, Process.ppid)
              sleep # wait for explicit kill to prevent GC disconnect
            end
            @client.query("SELECT sleep(2)")
            mark[:END] = Time.now
            mark.include?(:USR1).should be_true
            (mark[:USR1] - mark[:START]).should >= 1
            (mark[:USR1] - mark[:START]).should < 1.3
            (mark[:END] - mark[:USR1]).should > 0.9
            (mark[:END] - mark[:START]).should >= 2
            (mark[:END] - mark[:START]).should < 2.3
            Process.kill(:TERM, pid)
            Process.waitpid2(pid)
          ensure
            trap(:USR1, 'DEFAULT')
          end
        end
      end

      it "#socket should return a Fixnum (file descriptor from C)" do
        @client.socket.class.should eql(Fixnum)
        @client.socket.should_not eql(0)
      end

      it "#socket should require an open connection" do
        @client.close
        lambda {
          @client.socket
        }.should raise_error(Mysql2::Error)
      end

      it "should close the connection when an exception is raised" do
        begin
          Timeout.timeout(1, Timeout::Error) do
            @client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        lambda {
          @client.query("SELECT 1")
        }.should raise_error(Mysql2::Error, 'closed MySQL connection')
      end

      it "should handle Timeouts without leaving the connection hanging if reconnect is true" do
        client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:reconnect => true))
        begin
          Timeout.timeout(1, Timeout::Error) do
            client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        lambda {
          client.query("SELECT 1")
        }.should_not raise_error(Mysql2::Error)
      end

      it "should handle Timeouts without leaving the connection hanging if reconnect is set to true after construction true" do
        client = Mysql2::Client.new(DatabaseCredentials['root'])
        begin
          Timeout.timeout(1, Timeout::Error) do
            client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        lambda {
          client.query("SELECT 1")
        }.should raise_error(Mysql2::Error)

        client.reconnect = true

        begin
          Timeout.timeout(1, Timeout::Error) do
            client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        lambda {
          client.query("SELECT 1")
        }.should_not raise_error(Mysql2::Error)

      end

      it "threaded queries should be supported" do
        threads, results = [], {}
        lock = Mutex.new
        connect = lambda{
          Mysql2::Client.new(DatabaseCredentials['root'])
        }
        Timeout.timeout(0.7) do
          5.times {
            threads << Thread.new do
              result = connect.call.query("SELECT sleep(0.5) as result")
              lock.synchronize do
                results[Thread.current.object_id] = result
              end
            end
          }
        end
        threads.each{|t| t.join }
        results.keys.sort.should eql(threads.map{|t| t.object_id }.sort)
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
    end

    context "Multiple results sets" do
      before(:each) do
        @multi_client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:flags => Mysql2::Client::MULTI_STATEMENTS))
      end

      it "should raise an exception when one of multiple statements fails" do
        result = @multi_client.query("SELECT 1 as 'set_1'; SELECT * FROM invalid_table_name;SELECT 2 as 'set_2';")
        result.first['set_1'].should be(1)
        lambda {
          @multi_client.next_result
        }.should raise_error(Mysql2::Error)
        @multi_client.next_result.should be_false
      end

      it "returns multiple result sets" do
        @multi_client.query( "select 1 as 'set_1'; select 2 as 'set_2'").first.should eql({ 'set_1' => 1 })

        @multi_client.next_result.should be_true
        @multi_client.store_result.first.should eql({ 'set_2' => 2 })

        @multi_client.next_result.should be_false
      end

      it "does not interfere with other statements" do
        @multi_client.query( "select 1 as 'set_1'; select 2 as 'set_2'")
        while( @multi_client.next_result )
          @multi_client.store_result
        end

        @multi_client.query( "select 3 as 'next'").first.should == { 'next' => 3 }
      end

      it "will raise on query if there are outstanding results to read" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")
        lambda {
          @multi_client.query("SELECT 4")
        }.should raise_error(Mysql2::Error)
      end

      it "#abandon_results! should work" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")
        @multi_client.abandon_results!
        lambda {
          @multi_client.query("SELECT 4")
        }.should_not raise_error(Mysql2::Error)
      end

      it "#more_results? should work" do
        @multi_client.query( "select 1 as 'set_1'; select 2 as 'set_2'")
        @multi_client.more_results?.should be_true

        @multi_client.next_result
        @multi_client.store_result

        @multi_client.more_results?.should be_false
      end
    end
  end

  it "should respond to #socket" do
    @client.should respond_to(:socket)
  end

  if RUBY_PLATFORM =~ /mingw|mswin/
    it "#socket should raise as it's not supported" do
      lambda {
        @client.socket
      }.should raise_error(Mysql2::Error)
    end
  end

  it "should respond to escape" do
    Mysql2::Client.should respond_to(:escape)
  end

  context "escape" do
    it "should return a new SQL-escape version of the passed string" do
      Mysql2::Client.escape("abc'def\"ghi\0jkl%mno").should eql("abc\\'def\\\"ghi\\0jkl%mno")
    end

    it "should return the passed string if nothing was escaped" do
      str = "plain"
      Mysql2::Client.escape(str).object_id.should eql(str.object_id)
    end

    it "should not overflow the thread stack" do
      lambda {
        Thread.new { Mysql2::Client.escape("'" * 256 * 1024) }.join
      }.should_not raise_error(SystemStackError)
    end

    it "should not overflow the process stack" do
      lambda {
        Thread.new { Mysql2::Client.escape("'" * 1024 * 1024 * 4) }.join
      }.should_not raise_error(SystemStackError)
    end

    unless RUBY_VERSION =~ /1.8/
      it "should carry over the original string's encoding" do
        str = "abc'def\"ghi\0jkl%mno"
        escaped = Mysql2::Client.escape(str)
        escaped.encoding.should eql(str.encoding)

        str.encode!('us-ascii')
        escaped = Mysql2::Client.escape(str)
        escaped.encoding.should eql(str.encoding)
      end
    end
  end

  it "should respond to #escape" do
    @client.should respond_to(:escape)
  end

  context "#escape" do
    it "should return a new SQL-escape version of the passed string" do
      @client.escape("abc'def\"ghi\0jkl%mno").should eql("abc\\'def\\\"ghi\\0jkl%mno")
    end

    it "should return the passed string if nothing was escaped" do
      str = "plain"
      @client.escape(str).object_id.should eql(str.object_id)
    end

    it "should not overflow the thread stack" do
      lambda {
        Thread.new { @client.escape("'" * 256 * 1024) }.join
      }.should_not raise_error(SystemStackError)
    end

    it "should not overflow the process stack" do
      lambda {
        Thread.new { @client.escape("'" * 1024 * 1024 * 4) }.join
      }.should_not raise_error(SystemStackError)
    end

    it "should require an open connection" do
      @client.close
      lambda {
        @client.escape ""
      }.should raise_error(Mysql2::Error)
    end
  end

  it "should respond to #info" do
    @client.should respond_to(:info)
  end

  it "#info should return a hash containing the client version ID and String" do
    info = @client.info
    info.class.should eql(Hash)
    info.should have_key(:id)
    info[:id].class.should eql(Fixnum)
    info.should have_key(:version)
    info[:version].class.should eql(String)
  end

  if defined? Encoding
    context "strings returned by #info" do
      it "should default to the connection's encoding if Encoding.default_internal is nil" do
        with_internal_encoding nil do
          @client.info[:version].encoding.should eql(Encoding.find('utf-8'))

          client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
          client2.info[:version].encoding.should eql(Encoding.find('us-ascii'))
        end
      end

      it "should use Encoding.default_internal" do
        with_internal_encoding 'utf-8' do
          @client.info[:version].encoding.should eql(Encoding.default_internal)
        end

        with_internal_encoding 'us-ascii' do
          @client.info[:version].encoding.should eql(Encoding.default_internal)
        end
      end
    end
  end

  it "should respond to #server_info" do
    @client.should respond_to(:server_info)
  end

  it "#server_info should return a hash containing the client version ID and String" do
    server_info = @client.server_info
    server_info.class.should eql(Hash)
    server_info.should have_key(:id)
    server_info[:id].class.should eql(Fixnum)
    server_info.should have_key(:version)
    server_info[:version].class.should eql(String)
  end

  it "#server_info should require an open connection" do
    @client.close
    lambda {
      @client.server_info
    }.should raise_error(Mysql2::Error)
  end

  if defined? Encoding
    context "strings returned by #server_info" do
      it "should default to the connection's encoding if Encoding.default_internal is nil" do
        with_internal_encoding nil do
          @client.server_info[:version].encoding.should eql(Encoding.find('utf-8'))

          client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
          client2.server_info[:version].encoding.should eql(Encoding.find('us-ascii'))
        end
      end

      it "should use Encoding.default_internal" do
        with_internal_encoding 'utf-8' do
          @client.server_info[:version].encoding.should eql(Encoding.default_internal)
        end

        with_internal_encoding 'us-ascii' do
          @client.server_info[:version].encoding.should eql(Encoding.default_internal)
        end
      end
    end
  end

  it "should raise a Mysql2::Error exception upon connection failure" do
    lambda {
      Mysql2::Client.new :host => "localhost", :username => 'asdfasdf8d2h', :password => 'asdfasdfw42'
    }.should raise_error(Mysql2::Error)

    lambda {
      Mysql2::Client.new DatabaseCredentials['root']
    }.should_not raise_error(Mysql2::Error)
  end

  context 'write operations api' do
    before(:each) do
      @client.query "USE test"
      @client.query "CREATE TABLE IF NOT EXISTS lastIdTest (`id` BIGINT NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"
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

    it "#last_id should handle BIGINT auto-increment ids above 32 bits" do
      # The id column type must be BIGINT. Surprise: INT(x) is limited to 32-bits for all values of x.
      # Insert a row with a given ID, this should raise the auto-increment state
      @client.query "INSERT INTO lastIdTest (id, blah) VALUES (5000000000, 5000)"
      @client.last_id.should eql(5000000000)
      @client.query "INSERT INTO lastIdTest (blah) VALUES (5001)"
      @client.last_id.should eql(5000000001)
    end
  end

  it "should respond to #thread_id" do
    @client.should respond_to(:thread_id)
  end

  it "#thread_id should be a Fixnum" do
    @client.thread_id.class.should eql(Fixnum)
  end

  it "should respond to #ping" do
    @client.should respond_to(:ping)
  end

  context "select_db" do
    before(:each) do
      2.times do |i|
        @client.query("CREATE DATABASE test_selectdb_#{i}")
        @client.query("USE test_selectdb_#{i}")
        @client.query("CREATE TABLE test#{i} (`id` int NOT NULL PRIMARY KEY)")
      end
    end

    after(:each) do
      2.times do |i|
        @client.query("DROP DATABASE test_selectdb_#{i}")
      end
    end

    it "should respond to #select_db" do
      @client.should respond_to(:select_db)
    end

    it "should switch databases" do
      @client.select_db("test_selectdb_0")
      @client.query("SHOW TABLES").first.values.first.should eql("test0")
      @client.select_db("test_selectdb_1")
      @client.query("SHOW TABLES").first.values.first.should eql("test1")
      @client.select_db("test_selectdb_0")
      @client.query("SHOW TABLES").first.values.first.should eql("test0")
    end

    it "should raise a Mysql2::Error when the database doesn't exist" do
      lambda {
        @client.select_db("nopenothere")
      }.should raise_error(Mysql2::Error)
    end

    it "should return the database switched to" do
      @client.select_db("test_selectdb_1").should eq("test_selectdb_1")
    end
  end

  it "#thread_id should return a boolean" do
    @client.ping.should eql(true)
    @client.close
    @client.ping.should eql(false)
  end

  unless RUBY_VERSION =~ /1.8/
    it "should respond to #encoding" do
      @client.should respond_to(:encoding)
    end
  end
end
