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

      def query(sql, opts={})
        if ::EM.reactor_running?
          super(sql, opts.merge(:async => true))
          deferable = ::EM::DefaultDeferrable.new
          ::EM.watch(self.socket, Watcher, self, deferable).notify_readable = true
          deferable
        else
          super(sql, opts)
        end
      end
    end
  end
end