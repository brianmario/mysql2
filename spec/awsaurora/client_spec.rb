require 'mysql2/awsaurora'
require 'aws-sdk-rds'
require 'yaml'
DatabaseCredentials = YAML.load_file('spec/configuration.yml')

RSpec.describe Mysql2::AWSAurora::Client do

  context 'check reconnect on failover' do

    opts = DatabaseCredentials['aws']
    opts = Mysql2::Util.key_hash_as_symbols(opts)
    aws_opts = Mysql2::Util.key_hash_as_symbols(opts[:aws_opts])

    before(:each) do
      puts opts
      begin
        @mysql_client = Mysql2::AWSAurora::Client.new(opts)
        @rds_client = Aws::RDS::Client.new(
            Mysql2::Util.key_hash_as_symbols(aws_opts[:credentials])
        )
      rescue Exception => e
        skip("invalid configuration: " + e.backtrace)
      rescue Mysql2::Error => e
        skip("cannot connect to db: " + e.message )
      end
    end

    it 'tests reconnect on failover' do

      endpoint = @mysql_client.current_writer_endpoint

      @mysql_client.query("delete from users")

      @mysql_client.query("insert into users values('some text')")

      @rds_client.failover_db_cluster(
          {
              db_cluster_identifier: aws_opts[:db_cluster_identifier],
          })

      # wait until cluster writer change
      while true do
        new_endpoint = @mysql_client.current_writer_endpoint
        break if new_endpoint.address != endpoint.address

        sleep 1
      end

      @mysql_client.query("insert into users values('another text')")

      results = @mysql_client.query("select * from users;")

      expect(results.count).to eql(2)
    end

  end

end
