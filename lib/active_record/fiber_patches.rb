# Necessary monkeypatching to make AR fiber-friendly.

module ActiveRecord
  module ConnectionAdapters

    def self.fiber_pools
      @fiber_pools ||= []
    end
    def self.register_fiber_pool(fp)
      fiber_pools << fp
    end

    class FiberedMonitor
      class Queue
        def initialize
          @queue = []
        end

        def wait(timeout)
          t = timeout || 5
          fiber = Fiber.current
          x = EM::Timer.new(t) do
            @queue.delete(fiber)
            fiber.resume(false)
          end
          @queue << fiber
          Fiber.yield.tap do |fiber|
            x.cancel
          end
        end

        def signal
          fiber = @queue.pop
          fiber.resume(true) if fiber
        end
      end

      def synchronize
        yield
      end

      def new_cond
        Queue.new
      end
    end

    # ActiveRecord's connection pool is based on threads.  Since we are working
    # with EM and a single thread, multiple fiber design, we need to provide
    # our own connection pool that keys off of Fiber.current so that different
    # fibers running in the same thread don't try to use the same connection.
    class ConnectionPool
      def initialize(spec)
        @spec = spec

        # The cache of reserved connections mapped to threads
        @reserved_connections = {}

        # The mutex used to synchronize pool access
        @connection_mutex = FiberedMonitor.new
        @queue = @connection_mutex.new_cond

        # default 5 second timeout unless on ruby 1.9
        @timeout = spec.config[:wait_timeout] || 5

        # default max pool size to 5
        @size = (spec.config[:pool] && spec.config[:pool].to_i) || 5

        @connections = []
        @checked_out = []
      end


      def clear_stale_cached_connections!
        keys = @reserved_connections.keys

        ActiveRecord::ConnectionAdapters.fiber_pools.each do |pool|
          pool.busy_fibers.each_pair do |object_id, fiber|
            keys.delete(object_id)
          end
        end

        keys.each do |key|
          checkin @reserved_connections[key]
          @reserved_connections.delete(key)
        end
      end

      private

        def current_connection_id #:nodoc:
          Fiber.current.object_id
        end

        def checkout_and_verify(c)
          c.run_callbacks :checkout do
            c.verify!
            @checked_out << c
          end
          c
        end

    end
  end
end
