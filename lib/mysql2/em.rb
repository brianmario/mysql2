# encoding: utf-8

require 'eventmachine'
require 'mysql2'

module Mysql2
  module EM
    class Client < ::Mysql2::Client
      module Watcher
        def initialize(client, deferable)
          @client = client
          @deferable = deferable
        end

        def notify_readable
          detach
          begin
            @deferable.succeed(@client.async_result)
          rescue Exception => e
            @deferable.fail(e)
          end
        end
      end

      def query(sql, opts={}, deferable = nil)
        if ::EM.reactor_running?
          deferable ||= ::EM::DefaultDeferrable.new
          begin
            super(sql, opts.merge(:async => true))
            ::EM.watch(self.socket, Watcher, self, deferable).notify_readable = true
            deferable
          rescue Mysql2::AlreadyActiveError
            ::EM.add_timer(0.1) { self.query(sql, opts, deferable) }
            deferable
          end
        else
          super(sql, opts)
        end
      end
    end
  end
end