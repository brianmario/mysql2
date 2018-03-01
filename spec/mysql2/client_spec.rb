require 'spec_helper'

RSpec.describe Mysql2::Client do
  context "using defaults file" do
    let(:cnf_file) { File.expand_path('../../my.cnf', __FILE__) }

    it "should not raise an exception for valid defaults group" do
      expect do
        new_client(default_file: cnf_file, default_group: "test")
      end.not_to raise_error
    end

    it "should not raise an exception without default group" do
      expect do
        new_client(default_file: cnf_file)
      end.not_to raise_error
    end
  end

  it "should raise a Mysql::Error::ConnectionError upon connection failure" do
    expect do
      # The odd local host IP address forces the mysql client library to
      # use a TCP socket rather than a domain socket.
      new_client('host' => '127.0.0.2', 'port' => 999999)
    end.to raise_error(Mysql2::Error::ConnectionError)
  end

  it "should raise an exception on create for invalid encodings" do
    expect do
      new_client(encoding: "fake")
    end.to raise_error(Mysql2::Error)
  end

  it "should raise an exception on non-string encodings" do
    expect do
      new_client(encoding: :fake)
    end.to raise_error(TypeError)
  end

  it "should not raise an exception on create for a valid encoding" do
    expect do
      new_client(encoding: "utf8")
    end.not_to raise_error

    expect do
      new_client(DatabaseCredentials['root'].merge(encoding: "big5"))
    end.not_to raise_error
  end

  Klient = Class.new(Mysql2::Client) do
    attr_reader :connect_args
    def connect(*args)
      @connect_args ||= []
      @connect_args << args
    end
  end

  it "should accept connect flags and pass them to #connect" do
    client = Klient.new flags: Mysql2::Client::FOUND_ROWS
    expect(client.connect_args.last[6] & Mysql2::Client::FOUND_ROWS).to be > 0
  end

  it "should parse flags array" do
    client = Klient.new flags: %w[FOUND_ROWS -PROTOCOL_41]
    expect(client.connect_args.last[6] & Mysql2::Client::FOUND_ROWS).to eql(Mysql2::Client::FOUND_ROWS)
    expect(client.connect_args.last[6] & Mysql2::Client::PROTOCOL_41).to eql(0)
  end

  it "should parse flags string" do
    client = Klient.new flags: "FOUND_ROWS -PROTOCOL_41"
    expect(client.connect_args.last[6] & Mysql2::Client::FOUND_ROWS).to eql(Mysql2::Client::FOUND_ROWS)
    expect(client.connect_args.last[6] & Mysql2::Client::PROTOCOL_41).to eql(0)
  end

  it "should default flags to (REMEMBER_OPTIONS, LONG_PASSWORD, LONG_FLAG, TRANSACTIONS, PROTOCOL_41, SECURE_CONNECTION)" do
    client = Klient.new
    client_flags = Mysql2::Client::REMEMBER_OPTIONS |
                   Mysql2::Client::LONG_PASSWORD |
                   Mysql2::Client::LONG_FLAG |
                   Mysql2::Client::TRANSACTIONS |
                   Mysql2::Client::PROTOCOL_41 |
                   Mysql2::Client::SECURE_CONNECTION |
                   Mysql2::Client::CONNECT_ATTRS
    expect(client.connect_args.last[6]).to eql(client_flags)
  end

  it "should execute init command" do
    options = DatabaseCredentials['root'].dup
    options[:init_command] = "SET @something = 'setting_value';"
    client = new_client(options)
    result = client.query("SELECT @something;")
    expect(result.first['@something']).to eq('setting_value')
  end

  it "should send init_command after reconnect" do
    options = DatabaseCredentials['root'].dup
    options[:init_command] = "SET @something = 'setting_value';"
    options[:reconnect] = true
    client = new_client(options)

    result = client.query("SELECT @something;")
    expect(result.first['@something']).to eq('setting_value')

    # get the current connection id
    result = client.query("SELECT CONNECTION_ID()")
    first_conn_id = result.first['CONNECTION_ID()']

    # break the current connection
    expect { client.query("KILL #{first_conn_id}") }.to raise_error(Mysql2::Error)

    client.ping # reconnect now

    # get the new connection id
    result = client.query("SELECT CONNECTION_ID()")
    second_conn_id = result.first['CONNECTION_ID()']

    # confirm reconnect by checking the new connection id
    expect(first_conn_id).not_to eq(second_conn_id)

    # At last, check that the init command executed
    result = client.query("SELECT @something;")
    expect(result.first['@something']).to eq('setting_value')
  end

  it "should have a global default_query_options hash" do
    expect(Mysql2::Client).to respond_to(:default_query_options)
  end

  it "should be able to connect via SSL options" do
    ssl = @client.query "SHOW VARIABLES LIKE 'have_ssl'"
    ssl_uncompiled = ssl.any? { |x| x['Value'] == 'OFF' }
    pending("DON'T WORRY, THIS TEST PASSES - but SSL is not compiled into your MySQL daemon.") if ssl_uncompiled
    ssl_disabled = ssl.any? { |x| x['Value'] == 'DISABLED' }
    pending("DON'T WORRY, THIS TEST PASSES - but SSL is not enabled in your MySQL daemon.") if ssl_disabled

    # You may need to adjust the lines below to match your SSL certificate paths
    ssl_client = nil
    expect do
      ssl_client = new_client(
        'host'     => 'mysql2gem.example.com', # must match the certificates
        :sslkey    => '/etc/mysql/client-key.pem',
        :sslcert   => '/etc/mysql/client-cert.pem',
        :sslca     => '/etc/mysql/ca-cert.pem',
        :sslcipher => 'DHE-RSA-AES256-SHA',
        :sslverify => true,
      )
    end.not_to raise_error

    results = Hash[ssl_client.query('SHOW STATUS WHERE Variable_name LIKE "Ssl_%"').map { |x| x.values_at('Variable_name', 'Value') }]
    expect(results['Ssl_cipher']).not_to be_empty
    expect(results['Ssl_version']).not_to be_empty

    expect(ssl_client.ssl_cipher).not_to be_empty
    expect(results['Ssl_cipher']).to eql(ssl_client.ssl_cipher)
  end

  def run_gc
    if defined?(Rubinius)
      GC.run(true)
    else
      GC.start
    end
    sleep(0.5)
  end

  it "should terminate connections when calling close" do
    # rubocop:disable Lint/AmbiguousBlockAssociation
    expect do
      client = Mysql2::Client.new(DatabaseCredentials['root'])
      connection_id = client.thread_id
      client.close

      # mysql_close sends a quit command without waiting for a response
      # so give the server some time to handle the detect the closed connection
      closed = false
      10.times do
        closed = @client.query("SHOW PROCESSLIST").none? { |row| row['Id'] == connection_id }
        break if closed
        sleep(0.1)
      end
      expect(closed).to eq(true)
    end.to_not change {
      @client.query("SHOW STATUS LIKE 'Aborted_%'").to_a
    }
    # rubocop:enable Lint/AmbiguousBlockAssociation
  end

  it "should not leave dangling connections after garbage collection" do
    run_gc
    # rubocop:disable Lint/AmbiguousBlockAssociation
    expect do
      expect do
        10.times do
          Mysql2::Client.new(DatabaseCredentials['root']).query('SELECT 1')
        end
      end.to change {
        @client.query("SHOW STATUS LIKE 'Threads_connected'").first['Value'].to_i
      }.by(10)

      run_gc
    end.to_not change {
      @client.query("SHOW STATUS LIKE 'Aborted_%'").to_a +
        @client.query("SHOW STATUS LIKE 'Threads_connected'").to_a
    }
    # rubocop:enable Lint/AmbiguousBlockAssociation
  end

  context "#set_server_option" do
    let(:client) do
      new_client.tap do |client|
        client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_ON)
      end
    end

    it 'returns true when multi_statements is enable' do
      expect(client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_ON)).to be true
    end

    it 'returns true when multi_statements is disable' do
      expect(client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_OFF)).to be true
    end

    it 'returns false when multi_statements is neither OPTION_MULTI_STATEMENTS_OFF or OPTION_MULTI_STATEMENTS_ON' do
      expect(client.set_server_option(344)).to be false
    end

    it 'enables multiple-statement' do
      client.query("SELECT 1;SELECT 2;")

      expect(client.next_result).to be true
      expect(client.store_result.first).to eql('2' => 2)
      expect(client.next_result).to be false
    end

    it 'disables multiple-statement' do
      client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_OFF)

      expect { client.query("SELECT 1;SELECT 2;") }.to raise_error(Mysql2::Error)
    end
  end

  context "#automatic_close" do
    it "is enabled by default" do
      expect(new_client.automatic_close?).to be(true)
    end

    if RUBY_PLATFORM =~ /mingw|mswin/
      it "cannot be disabled" do
        expect do
          client = new_client(automatic_close: false)
          expect(client.automatic_close?).to be(true)
        end.to output(/always closed by garbage collector/).to_stderr

        expect do
          client = new_client(automatic_close: true)
          expect(client.automatic_close?).to be(true)
        end.to_not output(/always closed by garbage collector/).to_stderr

        expect do
          client = new_client(automatic_close: true)
          client.automatic_close = false
          expect(client.automatic_close?).to be(true)
        end.to output(/always closed by garbage collector/).to_stderr
      end
    else
      it "can be configured" do
        client = new_client(automatic_close: false)
        expect(client.automatic_close?).to be(false)
      end

      it "can be assigned" do
        client = new_client
        client.automatic_close = false
        expect(client.automatic_close?).to be(false)

        client.automatic_close = true
        expect(client.automatic_close?).to be(true)

        client.automatic_close = nil
        expect(client.automatic_close?).to be(false)

        client.automatic_close = 9
        expect(client.automatic_close?).to be(true)
      end

      it "should not close connections when running in a child process" do
        run_gc
        client = Mysql2::Client.new(DatabaseCredentials['root'])
        client.automatic_close = false

        child = fork do
          client.query('SELECT 1')
          client = nil
          run_gc
        end

        Process.wait(child)

        # this will throw an error if the underlying socket was shutdown by the
        # child's GC
        expect { client.query('SELECT 1') }.to_not raise_exception
        client.close
      end
    end
  end

  it "should be able to connect to database with numeric-only name" do
    database = 1235
    @client.query "CREATE DATABASE IF NOT EXISTS `#{database}`"

    expect do
      new_client('database' => database)
    end.not_to raise_error

    @client.query "DROP DATABASE IF EXISTS `#{database}`"
  end

  it "should respond to #close" do
    expect(@client).to respond_to(:close)
  end

  it "should be able to close properly" do
    expect(@client.close).to be_nil
    expect do
      @client.query "SELECT 1"
    end.to raise_error(Mysql2::Error)
  end

  context "#closed?" do
    it "should return false when connected" do
      expect(@client.closed?).to eql(false)
    end

    it "should return true after close" do
      @client.close
      expect(@client.closed?).to eql(true)
    end
  end

  it "should not try to query closed mysql connection" do
    client = new_client(reconnect: true)
    expect(client.close).to be_nil
    expect do
      client.query "SELECT 1"
    end.to raise_error(Mysql2::Error)
  end

  it "should respond to #query" do
    expect(@client).to respond_to(:query)
  end

  it "should respond to #warning_count" do
    expect(@client).to respond_to(:warning_count)
  end

  context "#warning_count" do
    context "when no warnings" do
      it "should 0" do
        @client.query('select 1')
        expect(@client.warning_count).to eq(0)
      end
    end
    context "when has a warnings" do
      it "should > 0" do
        # "the statement produces extra information that can be viewed by issuing a SHOW WARNINGS"
        # https://dev.mysql.com/doc/refman/5.7/en/show-warnings.html
        @client.query('DROP TABLE IF EXISTS test.no_such_table')
        expect(@client.warning_count).to be > 0
      end
    end
  end

  it "should respond to #query_info" do
    expect(@client).to respond_to(:query_info)
  end

  context "#query_info" do
    context "when no info present" do
      it "should 0" do
        @client.query('select 1')
        expect(@client.query_info).to be_empty
        expect(@client.query_info_string).to be_nil
      end
    end
    context "when has some info" do
      it "should retrieve it" do
        @client.query "USE test"
        @client.query "CREATE TABLE IF NOT EXISTS infoTest (`id` int(11) NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"

        # http://dev.mysql.com/doc/refman/5.0/en/mysql-info.html says
        # # Note that mysql_info() returns a non-NULL value for INSERT ... VALUES only for the multiple-row form of the statement (that is, only if multiple value lists are specified).
        @client.query("INSERT INTO infoTest (blah) VALUES (1234),(4535)")

        expect(@client.query_info).to eql(records: 2, duplicates: 0, warnings: 0)
        expect(@client.query_info_string).to eq('Records: 2  Duplicates: 0  Warnings: 0')

        @client.query "DROP TABLE infoTest"
      end
    end
  end

  context ":local_infile" do
    before(:all) do
      new_client(local_infile: true) do |client|
        local = client.query "SHOW VARIABLES LIKE 'local_infile'"
        local_enabled = local.any? { |x| x['Value'] == 'ON' }
        skip("DON'T WORRY, THIS TEST PASSES - but LOCAL INFILE is not enabled in your MySQL daemon.") unless local_enabled

        client.query %[
          CREATE TABLE IF NOT EXISTS infileTest (
            id MEDIUMINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
            foo VARCHAR(10),
            bar MEDIUMTEXT
          )
        ]
      end
    end

    after(:all) do
      new_client do |client|
        client.query "DROP TABLE IF EXISTS infileTest"
      end
    end

    it "should raise an error when local_infile is disabled" do
      client = new_client(local_infile: false)
      expect do
        client.query "LOAD DATA LOCAL INFILE 'spec/test_data' INTO TABLE infileTest"
      end.to raise_error(Mysql2::Error, /command is not allowed/)
    end

    it "should raise an error when a non-existent file is loaded" do
      client = new_client(local_infile: true)
      expect do
        client.query "LOAD DATA LOCAL INFILE 'this/file/is/not/here' INTO TABLE infileTest"
      end.to raise_error(Mysql2::Error, 'No such file or directory: this/file/is/not/here')
    end

    it "should LOAD DATA LOCAL INFILE" do
      client = new_client(local_infile: true)
      client.query "LOAD DATA LOCAL INFILE 'spec/test_data' INTO TABLE infileTest"
      info = client.query_info
      expect(info).to eql(records: 1, deleted: 0, skipped: 0, warnings: 0)

      result = client.query "SELECT * FROM infileTest"
      expect(result.first).to eql('id' => 1, 'foo' => 'Hello', 'bar' => 'World')
    end
  end

  it "should expect connect_timeout to be a positive integer" do
    expect do
      new_client(connect_timeout: -1)
    end.to raise_error(Mysql2::Error)
  end

  it "should expect read_timeout to be a positive integer" do
    expect do
      new_client(read_timeout: -1)
    end.to raise_error(Mysql2::Error)
  end

  it "should expect write_timeout to be a positive integer" do
    expect do
      new_client(write_timeout: -1)
    end.to raise_error(Mysql2::Error)
  end

  it "should allow nil read_timeout" do
    client = new_client(read_timeout: nil)

    expect(client.read_timeout).to be_nil
  end

  it "should set default program_name in connect_attrs" do
    client = new_client
    if Mysql2::Client::CONNECT_ATTRS.zero? || client.server_info[:version].match(/10.[01].\d+-MariaDB/)
      pending('Both client and server versions must be MySQL 5.6 or MariaDB 10.2 or later.')
    end
    result = client.query("SELECT attr_value FROM performance_schema.session_account_connect_attrs WHERE processlist_id = connection_id() AND attr_name = 'program_name'")
    expect(result.first['attr_value']).to eq($PROGRAM_NAME)
  end

  it "should set custom connect_attrs" do
    client = new_client(connect_attrs: { program_name: 'my_program_name', foo: 'fooval', bar: 'barval' })
    if Mysql2::Client::CONNECT_ATTRS.zero? || client.server_info[:version].match(/10.[01].\d+-MariaDB/)
      pending('Both client and server versions must be MySQL 5.6 or MariaDB 10.2 or later.')
    end
    results = Hash[client.query("SELECT * FROM performance_schema.session_account_connect_attrs WHERE processlist_id = connection_id()").map { |x| x.values_at('ATTR_NAME', 'ATTR_VALUE') }]
    expect(results['program_name']).to eq('my_program_name')
    expect(results['foo']).to eq('fooval')
    expect(results['bar']).to eq('barval')
  end

  context "#query" do
    it "should let you query again if iterating is finished when streaming" do
      @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false).each.to_a

      expect do
        @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false)
      end.to_not raise_error
    end

    it "should not let you query again if iterating is not finished when streaming" do
      @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false).first

      expect do
        @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false)
      end.to raise_exception(Mysql2::Error)
    end

    it "should only accept strings as the query parameter" do
      expect do
        @client.query ["SELECT 'not right'"]
      end.to raise_error(TypeError)
    end

    it "should not retain query options set on a query for subsequent queries, but should retain it in the result" do
      result = @client.query "SELECT 1", something: :else
      expect(@client.query_options[:something]).to be_nil
      expect(result.instance_variable_get('@query_options')).to eql(@client.query_options.merge(something: :else))
      expect(@client.instance_variable_get('@current_query_options')).to eql(@client.query_options.merge(something: :else))

      result = @client.query "SELECT 1"
      expect(result.instance_variable_get('@query_options')).to eql(@client.query_options)
      expect(@client.instance_variable_get('@current_query_options')).to eql(@client.query_options)
    end

    it "should allow changing query options for subsequent queries" do
      @client.query_options[:something] = :else
      result = @client.query "SELECT 1"
      expect(@client.query_options[:something]).to eql(:else)
      expect(result.instance_variable_get('@query_options')[:something]).to eql(:else)

      # Clean up after this test
      @client.query_options.delete(:something)
      expect(@client.query_options[:something]).to be_nil
    end

    it "should return results as a hash by default" do
      expect(@client.query("SELECT 1").first).to be_an_instance_of(Hash)
    end

    it "should be able to return results as an array" do
      expect(@client.query("SELECT 1", as: :array).first).to be_an_instance_of(Array)
      @client.query("SELECT 1").each(as: :array)
    end

    it "should be able to return results with symbolized keys" do
      expect(@client.query("SELECT 1", symbolize_keys: true).first.keys[0]).to be_an_instance_of(Symbol)
    end

    it "should require an open connection" do
      @client.close
      expect do
        @client.query "SELECT 1"
      end.to raise_error(Mysql2::Error)
    end

    it "should detect closed connection on query read error" do
      connection_id = @client.thread_id
      Thread.new do
        sleep(0.1)
        Mysql2::Client.new(DatabaseCredentials['root']).tap do |supervisor|
          supervisor.query("KILL #{connection_id}")
        end.close
      end
      expect do
        @client.query("SELECT SLEEP(1)")
      end.to raise_error(Mysql2::Error, /Lost connection to MySQL server/)

      if RUBY_PLATFORM !~ /mingw|mswin/
        expect do
          @client.socket
        end.to raise_error(Mysql2::Error, 'MySQL client is not connected')
      end
    end

    if RUBY_PLATFORM !~ /mingw|mswin/
      it "should not allow another query to be sent without fetching a result first" do
        @client.query("SELECT 1", async: true)
        expect do
          @client.query("SELECT 1")
        end.to raise_error(Mysql2::Error)
      end

      it "should describe the thread holding the active query" do
        thr = Thread.new { @client.query("SELECT 1", async: true) }

        thr.join
        expect { @client.query('SELECT 1') }.to raise_error(Mysql2::Error, Regexp.new(Regexp.escape(thr.inspect)))
      end

      it "should timeout if we wait longer than :read_timeout" do
        client = new_client(read_timeout: 0)
        expect do
          client.query('SELECT SLEEP(0.1)')
        end.to raise_error(Mysql2::Error::TimeoutError)
      end

      # XXX this test is not deterministic (because Unix signal handling is not)
      # and may fail on a loaded system
      it "should run signal handlers while waiting for a response" do
        kill_time = 0.1
        query_time = 2 * kill_time

        mark = {}

        begin
          trap(:USR1) { mark.store(:USR1, Time.now) }
          pid = fork do
            sleep kill_time # wait for client query to start
            Process.kill(:USR1, Process.ppid)
            sleep # wait for explicit kill to prevent GC disconnect
          end
          mark.store(:QUERY_START, Time.now)
          @client.query("SELECT SLEEP(#{query_time})")
          mark.store(:QUERY_END, Time.now)
        ensure
          Process.kill(:TERM, pid)
          Process.waitpid2(pid)
          trap(:USR1, 'DEFAULT')
        end

        # the query ran uninterrupted
        expect(mark.fetch(:QUERY_END) - mark.fetch(:QUERY_START)).to be_within(0.02).of(query_time)
        # signals fired while the query was running
        expect(mark.fetch(:USR1)).to be_between(mark.fetch(:QUERY_START), mark.fetch(:QUERY_END))
      end

      it "#socket should return a Fixnum (file descriptor from C)" do
        expect(@client.socket).to be_an_instance_of(0.class)
        expect(@client.socket).not_to eql(0)
      end

      it "#socket should require an open connection" do
        @client.close
        expect do
          @client.socket
        end.to raise_error(Mysql2::Error)
      end

      it 'should be impervious to connection-corrupting timeouts in #execute' do
        # attempt to break the connection
        stmt = @client.prepare('SELECT SLEEP(?)')
        expect { Timeout.timeout(0.1) { stmt.execute(0.2) } }.to raise_error(Timeout::Error)
        stmt.close

        # expect the connection to not be broken
        expect { @client.query('SELECT 1') }.to_not raise_error
      end

      context 'when a non-standard exception class is raised' do
        it "should close the connection when an exception is raised" do
          expect { Timeout.timeout(0.1, ArgumentError) { @client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { @client.query('SELECT 1') }.to raise_error(Mysql2::Error, 'MySQL client is not connected')
        end

        it "should handle Timeouts without leaving the connection hanging if reconnect is true" do
          if RUBY_PLATFORM.include?('darwin') && @client.server_info.fetch(:version).start_with?('5.5')
            pending('MySQL 5.5 on OSX is afflicted by an unknown bug that breaks this test. See #633 and #634.')
          end

          client = new_client(reconnect: true)

          expect { Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { client.query('SELECT 1') }.to_not raise_error
        end

        it "should handle Timeouts without leaving the connection hanging if reconnect is set to true after construction" do
          if RUBY_PLATFORM.include?('darwin') && @client.server_info.fetch(:version).start_with?('5.5')
            pending('MySQL 5.5 on OSX is afflicted by an unknown bug that breaks this test. See #633 and #634.')
          end

          client = new_client

          expect { Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { client.query('SELECT 1') }.to raise_error(Mysql2::Error)

          client.reconnect = true

          expect { Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { client.query('SELECT 1') }.to_not raise_error
        end
      end

      it "threaded queries should be supported" do
        sleep_time = 0.5

        # Note that each thread opens its own database connection
        threads = Array.new(5) do
          Thread.new do
            new_client do |client|
              client.query("SELECT SLEEP(#{sleep_time})")
            end
            Thread.current.object_id
          end
        end

        # This timeout demonstrates that the threads are sleeping concurrently:
        # In the serial case, the timeout would fire and the test would fail
        values = Timeout.timeout(sleep_time * 1.1) { threads.map(&:value) }

        expect(values).to match_array(threads.map(&:object_id))
      end

      it "evented async queries should be supported" do
        # should immediately return nil
        expect(@client.query("SELECT sleep(0.1)", async: true)).to eql(nil)

        io_wrapper = IO.for_fd(@client.socket, autoclose: false)
        loops = 0
        loops += 1 until IO.select([io_wrapper], nil, nil, 0.05)

        # make sure we waited some period of time
        expect(loops >= 1).to be true

        result = @client.async_result
        expect(result).to be_an_instance_of(Mysql2::Result)
      end
    end

    context "Multiple results sets" do
      before(:each) do
        @multi_client = new_client(flags: Mysql2::Client::MULTI_STATEMENTS)
      end

      it "should raise an exception when one of multiple statements fails" do
        result = @multi_client.query("SELECT 1 AS 'set_1'; SELECT * FROM invalid_table_name; SELECT 2 AS 'set_2';")
        expect(result.first['set_1']).to be(1)
        expect do
          @multi_client.next_result
        end.to raise_error(Mysql2::Error)
        expect(@multi_client.next_result).to be false
      end

      it "returns multiple result sets" do
        expect(@multi_client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'").first).to eql('set_1' => 1)

        expect(@multi_client.next_result).to be true
        expect(@multi_client.store_result.first).to eql('set_2' => 2)

        expect(@multi_client.next_result).to be false
      end

      it "does not interfere with other statements" do
        @multi_client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'")
        @multi_client.store_result while @multi_client.next_result

        expect(@multi_client.query("SELECT 3 AS 'next'").first).to eq('next' => 3)
      end

      it "will raise on query if there are outstanding results to read" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")
        expect do
          @multi_client.query("SELECT 4")
        end.to raise_error(Mysql2::Error)
      end

      it "#abandon_results! should work" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")
        @multi_client.abandon_results!
        expect do
          @multi_client.query("SELECT 4")
        end.not_to raise_error
      end

      it "#more_results? should work" do
        @multi_client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'")
        expect(@multi_client.more_results?).to be true

        @multi_client.next_result
        @multi_client.store_result

        expect(@multi_client.more_results?).to be false
      end

      it "#more_results? should work with stored procedures" do
        @multi_client.query("DROP PROCEDURE IF EXISTS test_proc")
        @multi_client.query("CREATE PROCEDURE test_proc() BEGIN SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'; END")
        expect(@multi_client.query("CALL test_proc()").first).to eql('set_1' => 1)
        expect(@multi_client.more_results?).to be true

        @multi_client.next_result
        expect(@multi_client.store_result.first).to eql('set_2' => 2)

        @multi_client.next_result
        expect(@multi_client.store_result).to be_nil # this is the result from CALL itself

        expect(@multi_client.more_results?).to be false
      end
    end
  end

  it "should respond to #socket" do
    expect(@client).to respond_to(:socket)
  end

  if RUBY_PLATFORM =~ /mingw|mswin/
    it "#socket should raise as it's not supported" do
      expect do
        @client.socket
      end.to raise_error(Mysql2::Error, /Raw access to the mysql file descriptor isn't supported on Windows/)
    end
  end

  it "should respond to escape" do
    expect(Mysql2::Client).to respond_to(:escape)
  end

  context "escape" do
    it "should return a new SQL-escape version of the passed string" do
      expect(Mysql2::Client.escape("abc'def\"ghi\0jkl%mno")).to eql("abc\\'def\\\"ghi\\0jkl%mno")
    end

    it "should return the passed string if nothing was escaped" do
      str = "plain"
      expect(Mysql2::Client.escape(str).object_id).to eql(str.object_id)
    end

    it "should not overflow the thread stack" do
      expect do
        Thread.new { Mysql2::Client.escape("'" * 256 * 1024) }.join
      end.not_to raise_error
    end

    it "should not overflow the process stack" do
      expect do
        Thread.new { Mysql2::Client.escape("'" * 1024 * 1024 * 4) }.join
      end.not_to raise_error
    end

    it "should carry over the original string's encoding" do
      str = "abc'def\"ghi\0jkl%mno"
      escaped = Mysql2::Client.escape(str)
      expect(escaped.encoding).to eql(str.encoding)

      str.encode!('us-ascii')
      escaped = Mysql2::Client.escape(str)
      expect(escaped.encoding).to eql(str.encoding)
    end
  end

  it "should respond to #escape" do
    expect(@client).to respond_to(:escape)
  end

  context "#escape" do
    it "should return a new SQL-escape version of the passed string" do
      expect(@client.escape("abc'def\"ghi\0jkl%mno")).to eql("abc\\'def\\\"ghi\\0jkl%mno")
    end

    it "should return the passed string if nothing was escaped" do
      str = "plain"
      expect(@client.escape(str).object_id).to eql(str.object_id)
    end

    it "should not overflow the thread stack" do
      expect do
        Thread.new { @client.escape("'" * 256 * 1024) }.join
      end.not_to raise_error
    end

    it "should not overflow the process stack" do
      expect do
        Thread.new { @client.escape("'" * 1024 * 1024 * 4) }.join
      end.not_to raise_error
    end

    it "should require an open connection" do
      @client.close
      expect do
        @client.escape ""
      end.to raise_error(Mysql2::Error)
    end

    context 'when mysql encoding is not utf8' do
      let(:client) { new_client(encoding: "ujis") }

      it 'should return a internal encoding string if Encoding.default_internal is set' do
        with_internal_encoding Encoding::UTF_8 do
          expect(client.escape("\u{30C6}\u{30B9}\u{30C8}")).to eq "\u{30C6}\u{30B9}\u{30C8}"
          expect(client.escape("\u{30C6}'\u{30B9}\"\u{30C8}")).to eq "\u{30C6}\\'\u{30B9}\\\"\u{30C8}"
        end
      end
    end
  end

  it "should respond to #info" do
    expect(@client).to respond_to(:info)
  end

  it "#info should return a hash containing the client version ID and String" do
    info = @client.info
    expect(info).to be_an_instance_of(Hash)
    expect(info).to have_key(:id)
    expect(info[:id]).to be_an_instance_of(0.class)
    expect(info).to have_key(:version)
    expect(info[:version]).to be_an_instance_of(String)
  end

  context "strings returned by #info" do
    it "should be tagged as ascii" do
      expect(@client.info[:version].encoding).to eql(Encoding::US_ASCII)
      expect(@client.info[:header_version].encoding).to eql(Encoding::US_ASCII)
    end
  end

  context "strings returned by .info" do
    it "should be tagged as ascii" do
      expect(Mysql2::Client.info[:version].encoding).to eql(Encoding::US_ASCII)
      expect(Mysql2::Client.info[:header_version].encoding).to eql(Encoding::US_ASCII)
    end
  end

  it "should respond to #server_info" do
    expect(@client).to respond_to(:server_info)
  end

  it "#server_info should return a hash containing the client version ID and String" do
    server_info = @client.server_info
    expect(server_info).to be_an_instance_of(Hash)
    expect(server_info).to have_key(:id)
    expect(server_info[:id]).to be_an_instance_of(0.class)
    expect(server_info).to have_key(:version)
    expect(server_info[:version]).to be_an_instance_of(String)
  end

  it "#server_info should require an open connection" do
    @client.close
    expect do
      @client.server_info
    end.to raise_error(Mysql2::Error)
  end

  context "strings returned by #server_info" do
    it "should default to the connection's encoding if Encoding.default_internal is nil" do
      with_internal_encoding nil do
        expect(@client.server_info[:version].encoding).to eql(Encoding::UTF_8)

        client2 = new_client(encoding: 'ascii')
        expect(client2.server_info[:version].encoding).to eql(Encoding::ASCII)
      end
    end

    it "should use Encoding.default_internal" do
      with_internal_encoding Encoding::UTF_8 do
        expect(@client.server_info[:version].encoding).to eql(Encoding.default_internal)
      end

      with_internal_encoding Encoding::ASCII do
        expect(@client.server_info[:version].encoding).to eql(Encoding.default_internal)
      end
    end
  end

  it "should raise a Mysql2::Error::ConnectionError exception upon connection failure due to invalid credentials" do
    expect do
      new_client(host: 'localhost', username: 'asdfasdf8d2h', password: 'asdfasdfw42')
    end.to raise_error(Mysql2::Error::ConnectionError)

    expect do
      new_client(DatabaseCredentials['root'])
    end.not_to raise_error
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
      expect(@client).to respond_to(:last_id)
    end

    it "#last_id should return a Fixnum, the from the last INSERT/UPDATE" do
      expect(@client.last_id).to eql(0)
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      expect(@client.last_id).to eql(1)
    end

    it "should respond to #last_id" do
      expect(@client).to respond_to(:last_id)
    end

    it "#last_id should return a Fixnum, the from the last INSERT/UPDATE" do
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      expect(@client.affected_rows).to eql(1)
      @client.query "UPDATE lastIdTest SET blah=4321 WHERE id=1"
      expect(@client.affected_rows).to eql(1)
    end

    it "#last_id should handle BIGINT auto-increment ids above 32 bits" do
      # The id column type must be BIGINT. Surprise: INT(x) is limited to 32-bits for all values of x.
      # Insert a row with a given ID, this should raise the auto-increment state
      @client.query "INSERT INTO lastIdTest (id, blah) VALUES (5000000000, 5000)"
      expect(@client.last_id).to eql(5000000000)
      @client.query "INSERT INTO lastIdTest (blah) VALUES (5001)"
      expect(@client.last_id).to eql(5000000001)
    end
  end

  it "should respond to #thread_id" do
    expect(@client).to respond_to(:thread_id)
  end

  it "#thread_id should be a Fixnum" do
    expect(@client.thread_id).to be_an_instance_of(0.class)
  end

  it "should respond to #ping" do
    expect(@client).to respond_to(:ping)
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
      expect(@client).to respond_to(:select_db)
    end

    it "should switch databases" do
      @client.select_db("test_selectdb_0")
      expect(@client.query("SHOW TABLES").first.values.first).to eql("test0")
      @client.select_db("test_selectdb_1")
      expect(@client.query("SHOW TABLES").first.values.first).to eql("test1")
      @client.select_db("test_selectdb_0")
      expect(@client.query("SHOW TABLES").first.values.first).to eql("test0")
    end

    it "should raise a Mysql2::Error when the database doesn't exist" do
      expect do
        @client.select_db("nopenothere")
      end.to raise_error(Mysql2::Error)
    end

    it "should return the database switched to" do
      expect(@client.select_db("test_selectdb_1")).to eq("test_selectdb_1")
    end
  end

  it "#thread_id should return a boolean" do
    expect(@client.ping).to eql(true)
    @client.close
    expect(@client.ping).to eql(false)
  end

  it "should be able to connect using plaintext password" do
    client = new_client(enable_cleartext_plugin: true)
    client.query('SELECT 1')
  end

  it "should respond to #encoding" do
    expect(@client).to respond_to(:encoding)
  end
end
