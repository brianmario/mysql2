module Mysql2
  class Statement
    include Enumerable

    def execute(*args)
      Thread.handle_interrupt(::Mysql2::Util::TIMEOUT_ERROR_CLASS => :never) do
        _execute(*args)
      end
    end
  end
end
