require 'mysql2/awsaurora'
require 'aws-sdk-rds'
require 'yaml'
require 'awsaurora/bank'
DatabaseCredentials = YAML.load_file('spec/configuration.yml')

RSpec.describe Mysql2::AWSAurora::Client do

  context 'check reconnect on failover' do

    opts = DatabaseCredentials['aws']
    opts = Mysql2::Util.key_hash_as_symbols(opts)
    aws_opts = Mysql2::Util.key_hash_as_symbols(opts[:aws_opts])
    opts[:logger] = Logger.new(STDOUT)

    before(:each) do
      begin
        @mysql_client = Mysql2::AWSAurora::Client.new(opts)
      rescue Mysql2::Error => e
        warn("cannot connect to db: " + e.message)
      rescue Exception => e
        warn(e.message)
        warn(e.backtrace)
      end
      begin
        @rds_client = Aws::RDS::Client.new(
            Mysql2::Util.key_hash_as_symbols(aws_opts[:credentials])
        )
      rescue Exception => e
        warn(e.backtrace)
      end
    end


    def current_writer_endpoint(db_cluster_identifier)
      resp = @rds_client.describe_db_clusters(
          {
              db_cluster_identifier: db_cluster_identifier,
          })

      clusters = resp.db_clusters[0]

      writer = clusters.db_cluster_members.find(&:is_cluster_writer)

      resp = @rds_client.describe_db_instances(
          {
              db_instance_identifier: writer.db_instance_identifier,
          })

      instance = resp.db_instances[0]

      instance.endpoint
    end

    it 'tests reconnect on failover' do
      endpoint = current_writer_endpoint(aws_opts[:db_cluster_identifier])

      @mysql_client.query("delete from users")

      @mysql_client.query("insert into users values('some text')")

      @rds_client.failover_db_cluster(
          {
              db_cluster_identifier: aws_opts[:db_cluster_identifier],
          })
      expect(@mysql_client.master_host_address).to eql endpoint.address

      count = 1
      # wait until cluster writer change
      while true do
        @mysql_client.query("insert into users values('another text')")
        count += 1
        new_endpoint = current_writer_endpoint(aws_opts[:db_cluster_identifier])
        break if new_endpoint.address != endpoint.address

        # puts "wait 1 sec #{new_endpoint.address} #{endpoint.address}"
        sleep 0.2
      end

      results = @mysql_client.query("select * from users;")

      expect(results.count).to eql(count)
      expect(@mysql_client.master_host_address).to eql new_endpoint.address
    end

  end

  context 'test transaction' do

    before(:each) do
      Bank.setup!
    end

    it 'with reconnect false' do
      prev_balance = Bank.fetch_total_balance
      expect(Bank.default_total_balance).to eql(prev_balance)

      expect {
        Bank.transfer_balance(client_options: {reconnect: false}) do |client1, client2|
          client2.query("KILL CONNECTION #{client1.thread_id}")
        end
      }.to raise_error Mysql2::Error

      expect(prev_balance).to eql(Bank.fetch_total_balance)
    end

    it 'with reconnect true' do
      prev_balance = Bank.fetch_total_balance
      expect(Bank.default_total_balance).to eql(prev_balance)


      expect {
        Bank.transfer_balance(client_options: {reconnect: true}) do |client1, client2|
          client2.query("KILL CONNECTION #{client1.thread_id}")
        end
      }.to raise_error Mysql2::Error

      expect(prev_balance).to eql(Bank.fetch_total_balance)
    end
  end
end
