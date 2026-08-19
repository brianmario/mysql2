module Mysql2
  class Statement
    def execute(*args, **kwargs)
      Thread.handle_interrupt(::Mysql2::Util::TIMEOUT_ERROR_NEVER) do
        _execute(*args, **kwargs)
      end
    end

    # Execute the prepared statement once per row of +rows+, an Array of
    # parameter Arrays, returning the batch's summed affected-rows count.
    #
    # On MariaDB Connector/C builds talking to a MariaDB 10.2+ server the
    # whole batch travels as a single COM_STMT_BULK_EXECUTE round trip;
    # everywhere else each row executes through the ordinary execute path.
    # Both paths enforce the same contract before the first row executes:
    # the statement must be DML (no result set), every row's arity must
    # match the statement's parameter count, and every non-nil value in a
    # column must bind as one type. +nil+ is SQL NULL anywhere.
    def execute_batch(rows)
      Thread.handle_interrupt(::Mysql2::Util::TIMEOUT_ERROR_NEVER) do
        if _bulk_execute_supported?
          _execute_bulk(rows)
        else
          _validate_batch(rows)
          rows.reduce(0) do |count, row|
            _execute(*row)
            count + affected_rows
          end
        end
      end
    end
  end
end
