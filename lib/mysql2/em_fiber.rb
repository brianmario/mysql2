# encoding: utf-8

require 'mysql2/em'
require 'fiber' unless defined? Fiber

module Mysql2
  module EM
    module Fiber
      class Client < ::Mysql2::EM::Client
        def query(sql, opts={})
          deferable = super(sql, opts)

          fiber = ::Fiber.current
          deferable.callback do |result|
            fiber.resume(result)
          end
          deferable.errback do |err|
            fiber.resume(err)
          end
          ::Fiber.yield
        end
      end
    end
  end
end