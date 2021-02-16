require 'mysql2'

module Mysql2
  module AWSAurora
    # Client for AWS Amazon Aurora. Can handle Amazon Aurora Fast-Failover.
    class Client < ::Mysql2::Client
      attr_reader :cluster_endpoints

      def initialize(opts = {})
        @opts = Mysql2::Util.key_hash_as_symbols(opts)
        super(@opts)
        @in_transaction = false

        return if defined? @initialized
        @initialized = true
        init
      end

      def update_servers_list
        results = query("select server_id, session_id from information_schema.replica_host_status " \
                            "where last_update_timestamp > now() - INTERVAL 3 MINUTE",)
        host_addresses = []
        results.each do |row|
          host_addresses.push(row["server_id"] + "." + @cluster_dns_suffix)
        end
        @cluster_endpoints = host_addresses if host_addresses
      end

      def query(sql, options = {})
        skip_reconnect = options[:skip_reconnect] || !@opts[:aws_reconnect]
        result = reconnect_with_readonly(skip_reconnect) do
          super(sql, options)
        end
        @in_transaction = true if sql.downcase.include?("begin") || sql.downcase.include?("start transaction")
        @in_transaction = false if sql.downcase.include?("commit")
        result
      end

      private

      def init
        @reconnect_attempts = @opts[:aws_reconnect_attempts] || 3
        @initial_retry_wait = @opts[:initial_retry_wait] || 0.5
        @max_retry_wait = @opts[:max_retry_wait]

        @aurora_dns_pattern = /(?<sub>.+)\.(?<cluster>cluster-)?(?<suffix>[a-zA-Z0-9]+\.[a-zA-Z0-9\\-]+\.rds\.amazonaws\.com)/i
        @master_host_address = nil
        @cluster_dns_suffix = nil
        @blacklist_endpoints = []
        @cluster_endpoints = []
        find_cluster_host_address(@opts[:host])
        if @opts[:cluster_endpoints]
          @cluster_endpoints = @opts[:cluster_endpoints]
        else
          update_servers_list
        end

        @opts[:host] = find_master_host if /(.+)\.cluster-([a-zA-Z0-9]+\.[a-zA-Z0-9\\-]+\.rds\.amazonaws\.com)/i =~ @opts[:host]
      end

      def reconnect_with_readonly(skip_reconnect, &block)
        retries = 0
        begin
          yield block if block_given?
        rescue Mysql2::Error => e
          puts e.message
          if retries < @reconnect_attempts && !skip_reconnect && !@in_transaction &&
             (e.message =~ /read-only/ || e.is_a?(Mysql2::Error::ConnectionError))
            retries += 1
            wait = @initial_retry_wait * retries
            wait = [wait, @max_retry_wait].min if @max_retry_wait
            current_host = @opts[:host]
            sleep wait
            begin
              @blacklist_endpoints.push(@opts[:host])
              endpoint = next_available_host
              reconnect(endpoint)
              update_servers_list unless @opts[:skip_update_servers]
              master_host_address = find_master_host
              reconnect(master_host_address) if master_host_address != endpoint
            rescue Mysql2::Error::ConnectionError => e
              retry if @opts[:host] != current_host
            end
            retry
          else
            raise e
          end
        rescue StandardError => e
          raise e
        end
      end

      def find_master_host
        results = query("select server_id, last_update_timestamp from information_schema.replica_host_status " \
                            "where session_id = 'MASTER_SESSION_ID' " \
                            "and last_update_timestamp > now() - INTERVAL 3 MINUTE " \
                            "ORDER BY last_update_timestamp DESC", skip_reconnect: true,)
        results.first["server_id"] + "." + @cluster_dns_suffix if results.count > 0
      end

      def find_cluster_host_address(host)
        if (matcher = @aurora_dns_pattern.match(host)) && @cluster_dns_suffix.nil?
          @cluster_dns_suffix = matcher[:suffix]
          host if !matcher[:cluster].nil? && !matcher[:cluster].empty?
        elsif matcher && @cluster_dns_suffix.casecmp(matcher[:suffix]) != 0
          raise "Connection string must contain only one aurora cluster. " + "'" +
                host + "' doesn't correspond to DNS prefix '" + @cluster_dns_suffix + "'"
        elsif @cluster_dns_suffix.nil? && host.contains(".")
          parts = host.split(".", 1)
          @cluster_dns_suffix = parts[1]
          nil
        end
      end

      def reconnect(endpoint)
        @opts[:host] = endpoint
        begin
          close
        rescue StandardError => e
          warn e
        end
        initialize(@opts)
      end

      def next_available_host
        @blacklist_endpoints &= @cluster_endpoints
        hosts = @cluster_endpoints - @blacklist_endpoints
        hosts += @blacklist_endpoints
        @blacklist_endpoints.clear if hosts == @blacklist_endpoints
        hosts[0]
      end
    end
  end
end
