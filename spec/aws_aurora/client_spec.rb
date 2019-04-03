require 'mysql2/aws_aurora'
require 'yaml'
require 'aws_aurora/bank'
require 'aws_aurora/aws_aurora_mock'
require 'logger'
DatabaseCredentials = YAML.load_file('spec/configuration.yml')

RSpec.describe Mysql2::AWSAurora::Client do

  AWSKlient = Class.new(Mysql2::AWSAurora::Client) do
    attr_reader :master_host_address
    def query(sql, opts = {})
      result_sql = sql.sub("information_schema.replica_host_status", "information_schema_mock.replica_host_status")
      super(result_sql, opts)
    end

    def find_master_host
      @master_host_address = super
    end
  end

  context 'check reconnect on failover' do

    options = DatabaseCredentials['aws'].dup
    options[:logger] = Logger.new(STDOUT)
    options[:aws_reconnect] = true

    before(:each) do
      begin
        servers = %w(mydbinstance mydbinstance-us-east-2b)
        @rds_client = AWSAuroraMock.new("xd5i43ct4fbx.us-east-2.rds.amazonaws.com", servers, options)
      rescue Mysql2::Error => e
        raise ("cannot connect to db: " + e.message)
      rescue Exception => e
        raise (e.backtrace)
      end
      begin
        @mysql_client = AWSKlient.new(options)
      rescue Mysql2::Error => e
        raise ("cannot connect to db: " + e.message)
      end
    end

    it 'tests reconnect on failover' do
      old_endpoint = @rds_client.current_writer
      expect(@mysql_client.master_host_address).to eql old_endpoint

      @mysql_client.query("create table IF NOT EXISTS users (value varchar(256));")
      @mysql_client.query("delete from users;")

      @mysql_client.query("insert into users values('some text');")

      current_endpoint = @rds_client.current_writer
      @rds_client.failover(0)

      count = 1
      # wait until cluster writer change
      while true do
        count += 1
        @mysql_client.query("insert into users values('#{count}');")
        current_endpoint = @rds_client.current_writer
        master_host_address = @mysql_client.master_host_address
        break if master_host_address != old_endpoint

        puts "wait 1 sec #{master_host_address} #{current_endpoint} #{old_endpoint}"
        sleep 0.2
      end

      results = @mysql_client.query("select count(*) as count from users;")

      expect(results.first["count"]).to eql(count)
      expect(@mysql_client.master_host_address).to eql current_endpoint

      @rds_client.failover

      # wait until cluster writer change
      while true do
        count += 1
        @mysql_client.query("insert into users values('#{count}');")
        current_endpoint = @rds_client.current_writer
        master_host_address = @mysql_client.master_host_address
        break if master_host_address == old_endpoint

        puts "wait 1 sec #{master_host_address} #{current_endpoint} #{old_endpoint}"
        sleep 0.2
      end

      results = @mysql_client.query("select count(*) as count from users;")

      expect(results.first["count"]).to eql(count)
      expect(@mysql_client.master_host_address).to eql current_endpoint

    end

  end

  context 'check servers list' do
    before(:each) do
      options = DatabaseCredentials['aws'].dup
      @opts = Mysql2::Util.key_hash_as_symbols(options)
      @opts[:logger] = Logger.new(STDOUT)

      begin
        servers = %w(mydbinstance mydbinstance-us-east-2b mydbinstance-us-east2c)
        @rds_client = AWSAuroraMock.new("xd5i43ct4fbx.us-east-2.rds.amazonaws.com", servers, @opts)
      rescue Mysql2::Error => e
        raise ("cannot connect to db: " + e.message)
      rescue Exception => e
        raise (e.backtrace)
      end
    end

    it 'sets initial server list' do
      endpoints = %w(mydbinstance.xd5i43ct4fbx.us-east-2.rds.amazonaws.com mydbinstance-us-east-2b.xd5i43ct4fbx.us-east-2.rds.amazonaws.com)
      @opts[:cluster_endpoints] = endpoints
      @opts[:skip_update_servers] = true
      mysql_client = AWSKlient.new(@opts)

      expect(mysql_client.cluster_endpoints).to eql(endpoints)
    end

    it 'updates server list from db' do
      endpoints = %w(mydbinstance.xd5i43ct4fbx.us-east-2.rds.amazonaws.com mydbinstance-us-east-2b.xd5i43ct4fbx.us-east-2.rds.amazonaws.com mydbinstance-us-east2c.xd5i43ct4fbx.us-east-2.rds.amazonaws.com)
      @opts[:skip_update_servers] = true
      mysql_client = AWSKlient.new(@opts)

      expect(mysql_client.cluster_endpoints).to eql(endpoints)
    end
  end

  context 'test transaction' do

    before(:each) do
      begin
        options = DatabaseCredentials['aws'].dup
        options[:logger] = Logger.new(STDOUT)
        servers = %w(mydbinstance mydbinstance-us-east-2b)
        @rds_client = AWSAuroraMock.new("xd5i43ct4fbx.us-east-2.rds.amazonaws.com", servers, options)
      rescue Mysql2::Error => e
        raise ("cannot connect to db: " + e.message)
      rescue Exception => e
        raise (e.backtrace)
      end
      Bank.setup!
    end

    it 'with reconnect false' do
      prev_balance = Bank.fetch_total_balance
      expect(Bank.default_total_balance).to eql(prev_balance)

      expect {
        Bank.transfer_balance(client_options: {reconnect: false}) do |client1, client2|
          client2.query("KILL #{client1.thread_id}")
        end
      }.to raise_error Mysql2::Error

      expect(prev_balance).to eql(Bank.fetch_total_balance)
    end

    it 'with reconnect true' do
      prev_balance = Bank.fetch_total_balance
      expect(Bank.default_total_balance).to eql(prev_balance)


      expect {
        Bank.transfer_balance(client_options: {reconnect: true}) do |client1, client2|
          client2.query("KILL #{client1.thread_id}")
        end
      }.to raise_error Mysql2::Error

      expect(prev_balance).to eql(Bank.fetch_total_balance)
    end
  end
end
