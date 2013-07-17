# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Client do
  test "raises an exception upon connection failure" do
    assert_raises Mysql2::Error do
      # The odd local host IP address forces the mysql client library to
      # use a TCP socket rather than a domain socket.
      Mysql2::Client.new DatabaseCredentials['root'].merge('host' => '127.0.0.2', 'port' => 999999)
    end
  end

  if defined? Encoding
    test "raises an exception on create for invalid encodings" do
      assert_raises Mysql2::Error do
        Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "fake"))
      end
    end

    test "doesn't raise an exception on create for a valid encoding" do
      assert_not_raised Mysql2::Error do
        Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "utf8"))
      end

      assert_not_raised Mysql2::Error do
        Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "big5"))
      end
    end
  end

  test "accepts connect flags and pass them to #connect" do
    klient = Class.new(Mysql2::Client) do
      attr_reader :connect_args
      def connect *args
        @connect_args ||= []
        @connect_args << args
      end
    end
    client = klient.new :flags => Mysql2::Client::FOUND_ROWS

    assert client.connect_args.last.last & Mysql2::Client::FOUND_ROWS
  end

  test "default flags to (REMEMBER_OPTIONS, LONG_PASSWORD, LONG_FLAG, TRANSACTIONS, PROTOCOL_41, SECURE_CONNECTION)" do
    klient = Class.new(Mysql2::Client) do
      attr_reader :connect_args
      def connect *args
        @connect_args ||= []
        @connect_args << args
      end
    end
    client = klient.new

    assert client.connect_args.last.last & (Mysql2::Client::REMEMBER_OPTIONS |
                                            Mysql2::Client::LONG_PASSWORD |
                                            Mysql2::Client::LONG_FLAG |
                                            Mysql2::Client::TRANSACTIONS |
                                            Mysql2::Client::PROTOCOL_41 |
                                            Mysql2::Client::SECURE_CONNECTION)
  end

  test "has a global default_query_options hash" do
    assert Mysql2::Client.respond_to?(:default_query_options)
  end

  test "able to connect via SSL options" do
    pending("DON'T WORRY, THIS TEST PASSES :) - but is machine-specific. You need to have MySQL running with SSL configured and enabled. Then update the paths in this test to your needs and remove the pending state.")
    ssl_client = nil

    assert_not_raised Mysql2::Error do
      ssl_client = Mysql2::Client.new(
        :sslkey => '/path/to/client-key.pem',
        :sslcert => '/path/to/client-cert.pem',
        :sslca => '/path/to/ca-cert.pem',
        :sslcapath => '/path/to/newcerts/',
        :sslcipher => 'DHE-RSA-AES256-SHA'
      )
    end

    results = ssl_client.query("SHOW STATUS WHERE Variable_name = \"Ssl_version\" OR Variable_name = \"Ssl_cipher\"").to_a
    assert_equal 'Ssl_cipher', results[0]['Variable_name']
    assert !results[0]['Value'].nil?
    assert_equal String, results[0]['Value'].class
    assert !results[0]['Value'].empty?

    assert_equal 'Ssl_version', results[1]['Variable_name']
    assert !results[1]['Value'].nil?
    assert_equal String, results[1]['Value'].class
    assert !results[1]['Value'].empty?

    ssl_client.close
  end

  test "responds to #close" do
    assert @client.respond_to?(:close)
  end

  test "able to close properly" do
    assert_nil @client.close

    assert_raises Mysql2::Error do
      @client.query "SELECT 1"
    end
  end

  test "responds to #query" do
    assert @client.respond_to?(:query)
  end

  test "responds to #warning_count" do
    assert @client.respond_to?(:warning_count)
  end

  context "#warning_count" do
    context "when no warnings" do
      test "warning count is 0" do
        @client.query('select 1')

        assert_equal 0, @client.warning_count
      end
    end
    context "when has a warnings" do
      test "warning count is > 0" do
        # "the statement produces extra information that can be viewed by issuing a SHOW WARNINGS"
        # http://dev.mysql.com/doc/refman/5.0/en/explain-extended.html
        @client.query("explain extended select 1")

        assert @client.warning_count > 0
      end
    end
  end

  test "responds to #query_info" do
    assert @client.respond_to?(:query_info)
  end

  context "#query_info" do
    context "when no info present" do
      test "is empty" do
        @client.query('select 1')
        assert @client.query_info.empty?
        assert_nil @client.query_info_string
      end
    end
    context "when has some info" do
      test "retrieve it" do
        @client.query "USE test"
        @client.query "CREATE TABLE IF NOT EXISTS infoTest (`id` int(11) NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"

        # http://dev.mysql.com/doc/refman/5.0/en/mysql-info.html says
        # # Note that mysql_info() returns a non-NULL value for INSERT ... VALUES only for the multiple-row form of the statement (that is, only if multiple value lists are specified).
        @client.query("INSERT INTO infoTest (blah) VALUES (1234),(4535)")

        hash = {:records => 2, :duplicates => 0, :warnings => 0}
        assert_equal hash, @client.query_info
        assert_equal 'Records: 2  Duplicates: 0  Warnings: 0', @client.query_info_string

        @client.query "DROP TABLE infoTest"
      end
    end
  end

  test "expects connect_timeout to be a positive integer" do
    assert_raises Mysql2::Error do
      Mysql2::Client.new(:connect_timeout => -1)
    end
  end

  test "expects read_timeout to be a positive integer" do
    assert_raises Mysql2::Error do
      Mysql2::Client.new(:read_timeout => -1)
    end
  end

  test "expects write_timeout to be a positive integer" do
    assert_raises Mysql2::Error do
      Mysql2::Client.new(:write_timeout => -1)
    end
  end

  context "#query" do
    test "lets you query again if iterating is finished when streaming" do
      @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false).each.to_a

      assert_not_raised Mysql2::Error do
        @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false)
      end
    end

    test "doesn't let you query again if iterating is not finished when streaming" do
      @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false).first

      assert_raises Mysql2::Error do
        @client.query("SELECT 1 UNION SELECT 2", :stream => true, :cache_rows => false)
      end
    end

    test "only accepts strings as the query parameter" do
      assert_raises TypeError do
        @client.query ["SELECT 'not right'"]
      end
    end

    test "doesn't retain query options set on a query for subsequent queries, but should retain it in the result" do
      result = @client.query "SELECT 1", :something => :else
      assert_nil @client.query_options[:something]
      assert_equal @client.query_options.merge(:something => :else), result.instance_variable_get('@query_options')
      assert_equal @client.query_options.merge(:something => :else), @client.instance_variable_get('@current_query_options')

      result = @client.query "SELECT 1"
      assert_equal @client.query_options, result.instance_variable_get('@query_options')
      assert_equal @client.query_options, @client.instance_variable_get('@current_query_options')
    end

    test "allows changing query options for subsequent queries" do
      @client.query_options.merge!(:something => :else)
      result = @client.query "SELECT 1"
      assert_equal :else, @client.query_options[:something]
      assert_equal :else, result.instance_variable_get('@query_options')[:something]

      # Clean up after this test
      @client.query_options.delete(:something)
      assert @client.query_options[:something].nil?
    end

    test "returns results as a hash by default" do
      assert_equal Hash, @client.query("SELECT 1").first.class
    end

    test "is able to return results as an array" do
      assert_equal Array, @client.query("SELECT 1", :as => :array).first.class
      assert_equal Array, @client.query("SELECT 1").each(:as => :array).first.class
    end

    test "be able to return results with symbolized keys" do
      assert_equal Symbol, @client.query("SELECT 1", :symbolize_keys => true).first.keys[0].class
    end

    test "requires an open connection" do
      @client.close

      assert_raises Mysql2::Error do
        @client.query "SELECT 1"
      end
    end

    if RUBY_PLATFORM !~ /mingw|mswin/
      test "doesn't allow another query to be sent without fetching a result first" do
        @client.query("SELECT 1", :async => true)

        assert_raises Mysql2::Error do
          @client.query("SELECT 1")
        end
      end

      test "describes the thread holding the active query" do
        thr = Thread.new { @client.query("SELECT 1", :async => true) }

        thr.join
        begin
          @client.query("SELECT 1")
        rescue Mysql2::Error => e
          message = e.message
        end
        re = Regexp.escape(thr.inspect)
        assert_match Regexp.new(re), message
      end

      test "will timeout if we wait longer than :read_timeout" do
        client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:read_timeout => 1))

        assert_raises Mysql2::Error do
          client.query("SELECT sleep(2)")
        end
      end

      if !defined? Rubinius
        # XXX this test is not deterministic (because Unix signal handling is not)
        # and may fail on a loaded system
        test "runs signal handlers while waiting for a response" do
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

            assert mark.include?(:USR1)
            assert (mark[:USR1] - mark[:START]) >= 1
            assert (mark[:USR1] - mark[:START]) < 1.3
            assert (mark[:END] - mark[:USR1]) > 0.9
            assert (mark[:END] - mark[:START]) >= 2
            assert (mark[:END] - mark[:START]) < 2.3

            Process.kill(:TERM, pid)
            Process.waitpid2(pid)
          ensure
            trap(:USR1, 'DEFAULT')
          end
        end
      end

      test "#socket returns a Fixnum (file descriptor from C)" do
        assert_equal Fixnum, @client.socket.class
        assert @client.socket != 0
      end

      test "#socket requires an open connection" do
        @client.close

        assert_raises Mysql2::Error do
          @client.socket
        end
      end

      test "closes the connection when an exception is raised" do
        begin
          Timeout.timeout(1) do
            @client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        assert_raises Mysql2::Error do
          @client.query("SELECT 1")
        end
      end

      test "handles Timeouts without leaving the connection hanging if reconnect is true" do
        client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:reconnect => true))
        begin
          Timeout.timeout(1) do
            client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        assert_not_raised Mysql2::Error do
          client.query("SELECT 1")
        end
      end

      test "handles Timeouts without leaving the connection hanging if reconnect is set to true after construction true" do
        client = Mysql2::Client.new(DatabaseCredentials['root'])
        begin
          Timeout.timeout(1) do
            client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        assert_raises Mysql2::Error do
          client.query("SELECT 1")
        end

        client.reconnect = true

        begin
          Timeout.timeout(1) do
            client.query("SELECT sleep(2)")
          end
        rescue Timeout::Error
        end

        assert_not_raised Mysql2::Error do
          client.query("SELECT 1")
        end
      end

      test "threaded queries are supported" do
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
        assert_equal threads.map{|t| t.object_id }.sort, results.keys.sort
      end

      test "evented async queries are supported" do
        # should immediately return nil
        assert_nil @client.query("SELECT sleep(0.1)", :async => true)

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
        assert loops >= 1

        result = @client.async_result
        assert_equal Mysql2::Result, result.class
      end
    end

    context "Multiple results sets" do
      before(:each) do
        @multi_client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:flags => Mysql2::Client::MULTI_STATEMENTS))
      end

      test "returns multiple result sets" do
        hash = {'set_1' => 1}
        assert_equal hash, @multi_client.query( "select 1 as 'set_1'; select 2 as 'set_2'").first

        assert @multi_client.next_result
        hash = {'set_2' => 2}
        assert_equal hash, @multi_client.store_result.first

        assert !@multi_client.next_result
      end

      test "does not interfere with other statements" do
        @multi_client.query( "select 1 as 'set_1'; select 2 as 'set_2'")
        while( @multi_client.next_result )
          @multi_client.store_result
        end

        @multi_client.query( "select 3 as 'next'").first.should == { 'next' => 3 }
      end

      test "will raise on query if there are outstanding results to read" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")

        assert_raises Mysql2::Error do
          @multi_client.query("SELECT 4")
        end
      end

      test "#abandon_results! works" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")
        @multi_client.abandon_results!

        assert_not_raised Mysql2::Error do
          @multi_client.query("SELECT 4")
        end
      end

      test "#more_results? works" do
        @multi_client.query( "select 1 as 'set_1'; select 2 as 'set_2'")
        assert @multi_client.more_results?

        @multi_client.next_result
        @multi_client.store_result

        assert !@multi_client.more_results?
      end
    end
  end

  test "responds to #socket" do
    assert @client.respond_to?(:socket)
  end

  if RUBY_PLATFORM =~ /mingw|mswin/
    test "#socket raises as it's not supported" do
      assert_raises Mysql2::Error do
        @client.socket
      end
    end
  end

  test "responds to escape" do
    assert Mysql2::Client.respond_to?(:escape)
  end

  context "escape" do
    test "returns a new SQL-escape version of the passed string" do
      assert_equal "abc\\'def\\\"ghi\\0jkl%mno", Mysql2::Client.escape("abc'def\"ghi\0jkl%mno")
    end

    test "returns the passed string if nothing was escaped" do
      str = "plain"
      assert_equal str.object_id, Mysql2::Client.escape(str).object_id
    end

    test "doesn't overflow the thread stack" do
      assert_not_raised SystemStackError do
        Thread.new { Mysql2::Client.escape("'" * 256 * 1024) }.join
      end
    end

    test "doesn't overflow the process stack" do
      assert_not_raised SystemStackError do
        Thread.new { Mysql2::Client.escape("'" * 1024 * 1024 * 4) }.join
      end
    end

    unless RUBY_VERSION =~ /1.8/
      test "carries over the original string's encoding" do
        str = "abc'def\"ghi\0jkl%mno"
        escaped = Mysql2::Client.escape(str)
        assert_equal str.encoding, escaped.encoding

        str.encode!('us-ascii')
        escaped = Mysql2::Client.escape(str)
        assert_equal str.encoding, escaped.encoding
      end
    end
  end

  test "responds to #escape" do
    assert @client.respond_to?(:escape)
  end

  context "#escape" do
    test "returns a new SQL-escape version of the passed string" do
      assert_equal "abc\\'def\\\"ghi\\0jkl%mno", @client.escape("abc'def\"ghi\0jkl%mno")
    end

    test "returns the passed string if nothing was escaped" do
      str = "plain"
      assert_equal str.object_id, @client.escape(str).object_id
    end

    test "doesn't overflow the thread stack" do
      assert_not_raised SystemStackError do
        Thread.new { @client.escape("'" * 256 * 1024) }.join
      end
    end

    test "doesn't overflow the process stack" do
      assert_not_raised SystemStackError do
        Thread.new { @client.escape("'" * 1024 * 1024 * 4) }.join
      end
    end

    test "requires an open connection" do
      @client.close
      assert_raises Mysql2::Error do
        @client.escape ""
      end
    end
  end

  test "responds to #info" do
    assert @client.respond_to?(:info)
  end

  test "#info returns a hash containing the client version ID and String" do
    info = @client.info
    assert_equal Hash, info.class
    assert info.has_key?(:id)
    assert_equal Fixnum, info[:id].class
    assert info.has_key?(:version)
    assert_equal String, info[:version].class
  end

  if defined? Encoding
    context "strings returned by #info" do
      test "defaults to the connection's encoding if Encoding.default_internal is nil" do
        Encoding.default_internal = nil
        assert_equal Encoding.find('utf-8'), @client.info[:version].encoding

        client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
        assert_equal Encoding.find('us-ascii'), client2.info[:version].encoding
      end

      test "uses Encoding.default_internal" do
        Encoding.default_internal = Encoding.find('utf-8')
        assert_equal Encoding.default_internal, @client.info[:version].encoding
        Encoding.default_internal = Encoding.find('us-ascii')
        assert_equal Encoding.default_internal, @client.info[:version].encoding
      end
    end
  end

  test "responds to #server_info" do
    assert @client.respond_to?(:server_info)
  end

  test "#server_info returns a hash containing the client version ID and String" do
    server_info = @client.server_info
    assert_equal Hash, server_info.class
    assert server_info.has_key?(:id)
    assert_equal Fixnum, server_info[:id].class
    assert server_info.has_key?(:version)
    assert_equal String, server_info[:version].class
  end

  test "#server_info requires an open connection" do
    @client.close
    assert_raises Mysql2::Error do
      @client.server_info
    end
  end

  if defined? Encoding
    context "strings returned by #server_info" do
      test "defaults to the connection's encoding if Encoding.default_internal is nil" do
        Encoding.default_internal = nil
        assert_equal Encoding.find('utf-8'), @client.server_info[:version].encoding

        client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => 'ascii'))
        assert_equal Encoding.find('us-ascii'), client2.server_info[:version].encoding
      end

      test "uses Encoding.default_internal" do
        Encoding.default_internal = Encoding.find('utf-8')
        assert_equal Encoding.default_internal, @client.server_info[:version].encoding
        Encoding.default_internal = Encoding.find('us-ascii')
        assert_equal Encoding.default_internal, @client.server_info[:version].encoding
      end
    end
  end

  test "raises a Mysql2::Error exception upon connection failure" do
    assert_raises Mysql2::Error do
      Mysql2::Client.new :host => "localhost", :username => 'asdfasdf8d2h', :password => 'asdfasdfw42'
    end

    assert_not_raised Mysql2::Error do
      Mysql2::Client.new DatabaseCredentials['root']
    end
  end

  context 'write operations api' do
    before(:each) do
      @client.query "USE test"
      @client.query "CREATE TABLE IF NOT EXISTS lastIdTest (`id` int(11) NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"
    end

    after(:each) do
      @client.query "DROP TABLE lastIdTest"
    end

    test "responds to #last_id" do
      assert @client.respond_to?(:last_id)
    end

    test "#last_id returns a Fixnum, the from the last INSERT/UPDATE" do
      assert_equal 0, @client.last_id
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      assert_equal 1, @client.last_id
    end

    test "responds to #last_id" do
      assert @client.respond_to?(:last_id)
    end

    test "#last_id returns a Fixnum, the from the last INSERT/UPDATE" do
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      assert_equal 1, @client.affected_rows
      @client.query "UPDATE lastIdTest SET blah=4321 WHERE id=1"
      assert_equal 1, @client.affected_rows
    end
  end

  test "responds to #thread_id" do
    @client.respond_to?(:thread_id)
  end

  test "#thread_id is a Fixnum" do
    assert_equal Fixnum, @client.thread_id.class
  end

  test "responds to #ping" do
    assert @client.respond_to?(:ping)
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

    test "responds to #select_db" do
      assert @client.respond_to?(:select_db)
    end

    test "is able to switch databases" do
      @client.select_db("test_selectdb_0")
      assert_equal "test0", @client.query("SHOW TABLES").first.values.first
      @client.select_db("test_selectdb_1")
      assert_equal "test1", @client.query("SHOW TABLES").first.values.first
      @client.select_db("test_selectdb_0")
      assert_equal "test0", @client.query("SHOW TABLES").first.values.first
    end

    test "raises a Mysql2::Error when the database doesn't exist" do
      assert_raises Mysql2::Error do
        @client.select_db("nopenothere")
      end
    end

    test "returns the database switched to" do
      assert_equal "test_selectdb_1", @client.select_db("test_selectdb_1")
    end
  end

  test "#thread_id returns a boolean" do
    assert @client.ping
    @client.close
    assert !@client.ping
  end

  unless RUBY_VERSION =~ /1.8/
    test "responds to #encoding" do
      assert @client.respond_to?(:encoding)
    end
  end
end
