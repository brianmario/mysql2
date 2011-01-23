# encoding: utf-8

require 'mysql2/em'
require 'fiber'

module Mysql2
  module EM
    module Fiber
      class Client < ::Mysql2::EM::Client
        def query(sql, opts={})
          if ::EM.reactor_running?
            deferable = super(sql, opts)

            fiber = ::Fiber.current
            deferable.callback do |result|
              fiber.resume(result)
            end
            deferable.errback do |err|
              fiber.resume(err)
            end
            ::Fiber.yield.tap do |result|
              raise result if result.is_a?(::Exception)
            end
          else
            super(sql, opts)
          end
        end
      end
    end
  end
end
