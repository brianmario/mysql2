require 'mysql2'

module Mysql2
  module AWSAurora
    class Client < ::Mysql2::Client

      def initialize(opts = {})
        opts = Mysql2::Util.key_hash_as_symbols(opts)
        @opts = opts

        @reconnect_attempts = opts[:reconnect_attempts] || 3
        @initial_retry_wait = opts[:initial_retry_wait] || 0.5
        @max_retry_wait = opts[:max_retry_wait]
        @logger = opts[:logger]

        aws_opts = Mysql2::Util.key_hash_as_symbols(@opts[:aws_opts])

        @rds_client = Aws::RDS::Client.new(
            Mysql2::Util.key_hash_as_symbols(aws_opts[:credentials])
        )

        super(@opts)
      end

      def reconnect_with_readonly(&block)
        retries = 0
        begin
          yield block
        rescue Mysql2::Error => e
          if e.message =~ /read-only/ || e.is_a?(Mysql2::Error::ConnectionError)
            if retries < @reconnect_attempts && @opts[:reconnect]
              wait = @initial_retry_wait * retries
              wait = [wait, @max_retry_wait].min if @max_retry_wait
              @logger.info {
                "Reconnect with readonly: #{e.message} " \
            "(retries: #{retries}/#{@reconnect_attempts}) (wait: #{wait}sec)"
              } if @logger
              sleep wait
              retries += 1
              reconnect
              @logger.debug { "Reconnect with readonly: disconnected and retry" } if @logger
              retry
              # raise e
            else
              warn "Reconnect with readonly: Give up " \
            "(retries: #{retries}/#{@reconnect_attempts})"
              raise e
            end
          else
            raise e
          end
        end
      end

      def reconnect
        endpoint = current_writer_endpoint
        @opts[:host] = endpoint.address
        @opts[:port] = endpoint.port
        close rescue nil
        #TODO: find current writer
        initialize(@opts)
      end

      def current_writer_endpoint

        aws_opts = @opts[:aws_opts]

        resp = @rds_client.describe_db_clusters(
            {
                db_cluster_identifier: aws_opts[:db_cluster_identifier],
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

      def query(sql, options = {})
        reconnect_with_readonly do
          super(sql, options)
        end
      end

    end
  end
end