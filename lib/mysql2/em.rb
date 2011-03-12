# encoding: utf-8

require 'eventmachine'
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
  end
end