require 'eventmachine'
require 'mysql2'

module Mysql2
  module EM
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

      def discard!(*args)
        @watch.detach if @watch && @watch.watching?

        super(*args)
      end

      def query(sql, opts = {})
        if ::EM.reactor_running?
          super(sql, opts.merge(async: true))
          deferable = ::EM::DefaultDeferrable.new
          @watch = ::EM.watch(socket, Watcher, self, deferable)
          @watch.notify_readable = true

          # :read_timeout has no effect on the synchronous wait mysql2 does
          # for a normal query (there is none here -- the whole point of
          # the async: true send above is that nothing blocks waiting for
          # the server), so it's applied here instead, as a timer on the
          # deferable.
          if @read_timeout
            timeout_error = Mysql2::Error::TimeoutError.new(
              "Timeout waiting for a response from the last query. (waited #{@read_timeout} seconds)",
            )
            deferable.timeout(@read_timeout, timeout_error)
            deferable.errback do |err|
              # Only for the timeout above, identified by object identity --
              # not any other failure. A real query error already reaches
              # here via Watcher#notify_readable, which detaches @watch and
              # fails the deferable with the actual exception; that path
              # completed a full round trip and leaves the connection fine
              # to reuse, same as a synchronous query error. A timeout is
              # different: the async read this method started never
              # completed, @watch is still registered, and a response may
              # still arrive late and be read as the reply to whatever
              # query runs next on this connection. Discard the connection
              # outright (which also detaches the now-orphaned watch, see
              # the override above) -- same reasoning as the synchronous
              # read_timeout path sacrificing the connection, and discard!
              # rather than close because sending a real QUIT on a
              # connection with an unread response in flight isn't safe
              # either.
              discard! if err.equal?(timeout_error)
            end
          end

          deferable
        else
          super(sql, opts)
        end
      end
    end
  end
end
