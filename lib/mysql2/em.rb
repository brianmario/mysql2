# encoding: utf-8

require 'eventmachine'
require 'fcntl'
require 'mysql2'

module Mysql2
  module EM
    class Client < ::Mysql2::Client
      module Watcher
        def initialize(client)
          @client = client
        end

        def notify_readable
          begin
            # TODO: buffer result bytes instead of calling blocking async_result
            @client.deferrable.succeed(@client.async_result)
          rescue Exception => e
            @client.deferrable.fail(e)
          ensure
            @client.deferrable = nil
            @client.next_query
          end
        end
      end

      attr_accessor :deferrable
      alias :query_now :query

      def initialize(*args, &blk)
        super(*args, &blk)
        @query_queue = []
      end

      def query(sql, opts={})
        if ::EM.reactor_running?
          deferrable = ::EM::DefaultDeferrable.new
          @query_queue << [sql, opts, deferrable]
          next_query if @deferrable.nil?
          deferrable
        else
          query_now(sql, opts)
        end
      end

      def next_query
        # TODO: does there need to be a detach on close line in here somewhere?
        @watch ||= (::EM.watch(self.socket, Watcher, self).notify_readable = true)
        if pending = @query_queue.shift
          sql, opts, deferrable = pending
          @deferrable = deferrable
          query_now(sql, opts.merge(:async => true))
        end
      end
    end

    # Hints taken from https://gist.github.com/636550
    class ClientPool
      def initialize(conf)
        @pool_size = conf[:size] || 4
        @connection_queue = []
        @query_queue = []
        @conf = conf
        connect
      end

      def connect
        @pool_size.times do |i|
          connection = Mysql2::EM::Client.new(@conf)
          flags = connection.fcntl(Fcntl::F_GETFD)
          connection.fcntl(Fcntl::F_SETFD, flags | Fcntl::FD_CLOEXEC)
          @connection_queue << connection
        end
      end

      def query(sql, opts={})
        deferrable = ::EM::DefaultDeferrable.new
        @query_queue << [sql, opts, deferrable]
        next_query
        deferrable
      end

      def next_query
        if @connection_queue.length > 0 and @query_queue.length > 0
          conn = @connection_queue.shift
          sql, opts, deferrable = @query_queue.shift
          begin
            after_query = conn.query(sql, opts)
          rescue Mysql2::Error
            @connection_queue.push conn
            raise
          end
          after_query.callback do |result|
            deferrable.succeed(result)
            @connection_queue.push conn
            next_query
          end
          after_query.errback do |result|
            deferrable.fail(result)
            @connection_queue.push conn
            next_query
          end
        end
      end
    end
  end
end