require 'eventmachine'
require 'mysql2'

module Mysql2
  module EM
    class ReadTimeout < ::RuntimeError; end

    class Client < ::Mysql2::Client
      module Watcher
        def initialize(client, deferable)
          @client = client
          @deferable = deferable
          @is_watching = true
        end

        def notify_readable
          detach
          begin
            result = @client.async_result
          rescue StandardError => e
            @deferable.fail(e)
          else
            @deferable.succeed(result)
          end
        end

        def watching?
          @is_watching
        end

        def unbind
          @is_watching = false
        end
      end

      def close(*args)
        @watch.detach if @watch && @watch.watching?

        super(*args)
      end

      def query(sql, opts = {})
        if ::EM.reactor_running?
          super(sql, opts.merge(async: true))
          deferable = ::EM::DefaultDeferrable.new
          if @read_timeout
            deferable.timeout(@read_timeout, Mysql2::EM::ReadTimeout.new)
            deferable.errback do |error|
              raise error if error.is_a?(Mysql2::EM::ReadTimeout)
            end
          end
          @watch = ::EM.watch(socket, Watcher, self, deferable)
          @watch.notify_readable = true
          deferable
        else
          super(sql, opts)
        end
      end
    end
  end
end
