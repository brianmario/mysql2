# encoding: UTF-8

module Mysql2
  class Statement
    attr_reader :query_options
    include Enumerable

    if Thread.respond_to?(:handle_interrupt)
      def execute(*args)
        Thread.handle_interrupt(::Mysql2::Util::TIMEOUT_ERROR_CLASS => :never) do
          _execute(*args)
        end
      end
    else
      def execute(*args)
        _execute(*args)
      end
    end
  end
end
