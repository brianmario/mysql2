require 'rspec'
require 'mysql2'
require 'timeout'
require 'yaml'
require 'fiber'

DatabaseCredentials = YAML.load_file('spec/configuration.yml')

if GC.respond_to?(:verify_compaction_references)
  # This method was added in Ruby 3.0.0. Calling it this way asks the GC to
  # move objects around, helping to find object movement bugs.
  if RUBY_VERSION >= "3.2"
    GC.verify_compaction_references(expand_heap: true, toward: :empty)
  else
    GC.verify_compaction_references(double_heap: true, toward: :empty)
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!

  def with_internal_encoding(encoding)
    old_enc = Encoding.default_internal
    old_verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_internal = encoding
    $VERBOSE = old_verbose

    yield
  ensure
    $VERBOSE = nil
    Encoding.default_internal = old_enc
    $VERBOSE = old_verbose
  end

  def new_client(option_overrides = {})
    client = Mysql2::Client.new(DatabaseCredentials['root'].merge(option_overrides))
    @clients ||= []
    @clients << client
    return client unless block_given?

    begin
      yield client
    ensure
      client.close
      @clients.delete(client)
    end
  end

  def num_classes
    # rubocop:disable Lint/UnifiedInteger
    0.instance_of?(Integer) ? [Integer] : [Fixnum, Bignum]
    # rubocop:enable Lint/UnifiedInteger
  end

  # Use monotonic time if possible (ruby >= 2.1.0)
  if defined?(Process::CLOCK_MONOTONIC)
    def clock_time
      Process.clock_gettime Process::CLOCK_MONOTONIC
    end
  else
    def clock_time
      Time.now.to_f
    end
  end

  # A directory where SSL certificates pem files exist.
  def ssl_cert_dir
    return @ssl_cert_dir if @ssl_cert_dir

    dir = ENV['TEST_RUBY_MYSQL2_SSL_CERT_DIR']
    @ssl_cert_dir = if dir && !dir.empty?
      dir
    else
      '/etc/mysql'
    end
    @ssl_cert_dir
  end

  config.before(:suite) do
    begin
      new_client
    rescue Mysql2::Error => e
      username = DatabaseCredentials['root']['username']
      database = DatabaseCredentials['root']['database']
      message = %(
An error occurred while connecting to the testing database server.
Make sure that the database server is running.
Make sure that `mysql -u #{username} [options] #{database}` succeeds by the root user config in spec/configuration.yml.
Make sure that the testing database '#{database}' exists. If it does not exist, create it.
)
      warn message
      raise e
    end
  end

  config.before(:context) do
    new_client do |client|
      client.query %[
        CREATE TABLE IF NOT EXISTS mysql2_test (
          id MEDIUMINT NOT NULL AUTO_INCREMENT,
          null_test VARCHAR(10),
          bit_test BIT(64),
          single_bit_test BIT(1),
          tiny_int_test TINYINT,
          bool_cast_test TINYINT(1),
          small_int_test SMALLINT,
          medium_int_test MEDIUMINT,
          int_test INT,
          big_int_test BIGINT,
          float_test FLOAT(10,3),
          float_zero_test FLOAT(10,3),
          double_test DOUBLE(10,3),
          decimal_test DECIMAL(10,3),
          decimal_zero_test DECIMAL(10,3),
          date_test DATE,
          date_time_test DATETIME,
          timestamp_test TIMESTAMP,
          time_test TIME,
          year_test YEAR(4),
          char_test CHAR(10),
          varchar_test VARCHAR(10),
          binary_test BINARY(10),
          varbinary_test VARBINARY(10),
          tiny_blob_test TINYBLOB,
          tiny_text_test TINYTEXT,
          blob_test BLOB,
          text_test TEXT,
          medium_blob_test MEDIUMBLOB,
          medium_text_test MEDIUMTEXT,
          long_blob_test LONGBLOB,
          long_text_test LONGTEXT,
          enum_test ENUM('val1', 'val2'),
          set_test SET('val1', 'val2'),
          PRIMARY KEY (id)
        )
      ]
      client.query "DELETE FROM mysql2_test;"
      client.query %[
        INSERT INTO mysql2_test (
          null_test, bit_test, single_bit_test, tiny_int_test, bool_cast_test, small_int_test, medium_int_test, int_test, big_int_test,
          float_test, float_zero_test, double_test, decimal_test, decimal_zero_test, date_test, date_time_test, timestamp_test, time_test,
          year_test, char_test, varchar_test, binary_test, varbinary_test, tiny_blob_test,
          tiny_text_test, blob_test, text_test, medium_blob_test, medium_text_test,
          long_blob_test, long_text_test, enum_test, set_test
        )

        VALUES (
          NULL, b'101', b'1', 1, 1, 10, 10, 10, 10,
          10.3, 0, 10.3, 10.3, 0, '2010-4-4', '2010-4-4 11:44:00', '2010-4-4 11:44:00', '11:44:00',
          2009, "test", "test", "test", "test", "test",
          "test", "test", "test", "test", "test",
          "test", "test", 'val1', 'val1,val2'
        )
      ]
    end
  end

  config.before(:example) do
    @client = new_client
  end

  config.after(:example) do
    @clients.each(&:close)
  end
end
