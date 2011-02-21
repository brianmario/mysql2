# encoding: utf-8

# AR adapter for using a fibered mysql2 connection with EM
# This adapter should be used within Thin or Unicorn with the rack-fiber_pool middleware.
# Just update your database.yml's adapter to be 'em_mysql2'

module ActiveRecord
  class Base
    def self.em_mysql2_connection(config)
      client = ::Mysql2::Fibered::Client.new(config.symbolize_keys)
      options = [config[:host], config[:username], config[:password], config[:database], config[:port], config[:socket], 0]
      ConnectionAdapters::Mysql2Adapter.new(client, logger, options, config)
    end
  end
end

require 'fiber'
require 'eventmachine'
require 'mysql2'
require 'active_record/connection_adapters/mysql2_adapter'
require 'active_record/fiber_patches'

module Mysql2
  module Fibered
    class Client < ::Mysql2::Client
      module Watcher
        def initialize(client, deferable)
          @client = client
          @deferable = deferable
        end

        def notify_readable
          begin
            detach
            results = @client.async_result
            @deferable.succeed(results)
          rescue Exception => e
            @deferable.fail(e)
          end
        end
      end

      def query(sql, opts={})
        if ::EM.reactor_running?
          super(sql, opts.merge(:async => true))
          deferrable = ::EM::DefaultDeferrable.new
          ::EM.watch(self.socket, Watcher, self, deferrable).notify_readable = true
          fiber = Fiber.current
          deferrable.callback do |result|
            fiber.resume(result)
          end
          deferrable.errback do |err|
            fiber.resume(err)
          end
          Fiber.yield.tap do |result|
            raise result if result.is_a?(Exception)
          end
        else
          super(sql, opts)
        end
      end
    end
  end
end