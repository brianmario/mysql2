require 'mysql2'

module Mysql2
  module AWSAurora
    class Client < ::Mysql2::Client
      attr_reader :opts, :master_host_address

      def initialize(opts = {})
        @opts = Mysql2::Util.key_hash_as_symbols(opts)
        unless @aurora_dns_pattern
          @aurora_dns_pattern = /(?<sub>.+)\.(?<cluster>cluster-)?(?<suffix>[a-zA-Z0-9]+\.[a-zA-Z0-9\\-]+\.rds\.amazonaws\.com)/i
          @master_host_address = nil
          @cluster_dns_suffix = nil
          @blacklist_endpoints = []
          @cluster_endpoints = []
          find_cluster_host_address(@opts[:host])
        end

        @reconnect_attempts = @opts[:reconnect_attempts] || 3
        @initial_retry_wait = @opts[:initial_retry_wait] || 0.5
        @max_retry_wait = @opts[:max_retry_wait]
        @logger = @opts[:logger]
        super(@opts)
        @logger.debug "connected to #{@opts[:host]}" if @logger

        update_servers_list
        unless @master_host_address
          @opts[:host] = find_master_host
        end
      end

      def find_cluster_host_address(host)
        if (matcher = @aurora_dns_pattern.match(host))
          if @cluster_dns_suffix.nil?
            @cluster_dns_suffix = matcher[:suffix]
          else
            if @cluster_dns_suffix.casecmp(matcher[:suffix]) != 0
              raise "Connection string must contain only one aurora cluster. " + "'" +
                        host + "' doesn't correspond to DNS prefix '" + @cluster_dns_suffix + "'"
            end
          end

          if !matcher[:cluster].nil? && !matcher[:cluster].empty?
            return host;
          end
        else
          if @cluster_dns_suffix.nil? && host.contains(".")
            parts = host.split(".", 1)
            @cluster_dns_suffix = parts[1]
          end
        end
        nil
      end

      def update_servers_list
        results = query("select server_id, session_id from information_schema.replica_host_status " +
                            "where last_update_timestamp > now() - INTERVAL 3 MINUTE")
        host_addresses = []
        results.each do |row|
          host_addresses.push(row["server_id"] + "." + @cluster_dns_suffix)
        end
        if host_addresses
          @cluster_endpoints = host_addresses
        end
        @logger.debug results.to_a if @logger
      end

      def reconnect_with_readonly(&block)
        retries = 0
        begin
          yield block
        rescue Mysql2::Error => e
          if e.message =~ /read-only/ || e.is_a?(Mysql2::Error::ConnectionError)
            if retries < @reconnect_attempts && @opts[:reconnect]
              retries += 1
              wait = @initial_retry_wait * retries
              wait = [wait, @max_retry_wait].min if @max_retry_wait
              @logger.info {
                "Reconnect with readonly: #{e.message} " \
            "(retries: #{retries}/#{@reconnect_attempts}) (wait: #{wait}sec)"
              } if @logger
              current_host = @opts[:host]
              sleep wait
              begin
                @blacklist_endpoints.push(@opts[:host])
                endpoint = next_available_host
                reconnect(endpoint)
                find_master_host
                if @master_host_address != endpoint
                  reconnect(@master_host_address)
                end
              rescue Mysql2::Error::ConnectionError => e
                @logger.warn e.message if @logger
                if @opts[:host] != current_host
                  retry
                end
              end
              @logger.debug {"Reconnect with readonly: disconnected and retry"} if @logger
              retry
              # raise e
            else
              @logger.warn "Reconnect with readonly: Give up " \
            "(retries: #{retries}/#{@reconnect_attempts})" if @logger
              raise e
            end
          else
            raise e
          end
        end
      end

      def next_available_host
        @blacklist_endpoints = @blacklist_endpoints & @cluster_endpoints
        hosts = @cluster_endpoints - @blacklist_endpoints
        hosts = hosts + @blacklist_endpoints
        if hosts == @blacklist_endpoints
          @blacklist_endpoints.clear
        end
        hosts[0]
      end

      def query(sql, options = {})
        reconnect_with_readonly do
          super(sql, options)
        end
      end

      private

      def find_master_host
        results = query("select server_id from information_schema.replica_host_status " +
        "where session_id = 'MASTER_SESSION_ID' " +
        "and last_update_timestamp > now() - INTERVAL 3 MINUTE " +
        "ORDER BY last_update_timestamp DESC LIMIT 1")

        if results.count > 0
          @master_host_address = results.first["server_id"] + "." + @cluster_dns_suffix
        end
        @master_host_address
      end

      def reconnect(endpoint)
        @opts[:host] = endpoint
        close rescue nil
        initialize(@opts)
      end
    end
  end
end