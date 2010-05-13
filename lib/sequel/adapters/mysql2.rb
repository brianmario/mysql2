require 'mysql2' unless defined? Mysql2

Sequel.require %w'shared/mysql utils/stored_procedures', 'adapters'

module Sequel
  # Module for holding all MySQL-related classes and modules for Sequel.
  module Mysql2
    # Mapping of type numbers to conversion procs
    MYSQL_TYPES = {}

    MYSQL2_LITERAL_PROC = lambda{|v| v}

    # Use only a single proc for each type to save on memory
    MYSQL_TYPE_PROCS = {
      [0, 246]  => MYSQL2_LITERAL_PROC,                               # decimal
      [1]  => lambda{|v| convert_tinyint_to_bool ? v != 0 : v},       # tinyint
      [2, 3, 8, 9, 13, 247, 248]  => MYSQL2_LITERAL_PROC,             # integer
      [4, 5]  => MYSQL2_LITERAL_PROC,                                 # float
      [10, 14]  => MYSQL2_LITERAL_PROC,                               # date
      [7, 12] => MYSQL2_LITERAL_PROC,                                # datetime
      [11]  => MYSQL2_LITERAL_PROC,                                   # time
      [249, 250, 251, 252]  => lambda{|v| Sequel::SQL::Blob.new(v)}   # blob
    }
    MYSQL_TYPE_PROCS.each do |k,v|
      k.each{|n| MYSQL_TYPES[n] = v}
    end

    @convert_invalid_date_time = false
    @convert_tinyint_to_bool = true

    class << self
      # By default, Sequel raises an exception if in invalid date or time is used.
      # However, if this is set to nil or :nil, the adapter treats dates
      # like 0000-00-00 and times like 838:00:00 as nil values.  If set to :string,
      # it returns the strings as is.
      attr_accessor :convert_invalid_date_time

      # Sequel converts the column type tinyint(1) to a boolean by default when
      # using the native MySQL adapter.  You can turn off the conversion by setting
      # this to false.
      attr_accessor :convert_tinyint_to_bool
    end

    # Database class for MySQL databases used with Sequel.
    class Database < Sequel::Database
      include Sequel::MySQL::DatabaseMethods

      # Mysql::Error messages that indicate the current connection should be disconnected
      MYSQL_DATABASE_DISCONNECT_ERRORS = /\A(Commands out of sync; you can't run this command now|Can't connect to local MySQL server through socket|MySQL server has gone away)/

      set_adapter_scheme :mysql2

      # Support stored procedures on MySQL
      def call_sproc(name, opts={}, &block)
        args = opts[:args] || []
        execute("CALL #{name}#{args.empty? ? '()' : literal(args)}", opts.merge(:sproc=>false), &block)
      end

      # Connect to the database.  In addition to the usual database options,
      # the following options have effect:
      #
      # * :auto_is_null - Set to true to use MySQL default behavior of having
      #   a filter for an autoincrement column equals NULL to return the last
      #   inserted row.
      # * :charset - Same as :encoding (:encoding takes precendence)
      # * :compress - Set to false to not compress results from the server
      # * :config_default_group - The default group to read from the in
      #   the MySQL config file.
      # * :config_local_infile - If provided, sets the Mysql::OPT_LOCAL_INFILE
      #   option on the connection with the given value.
      # * :encoding - Set all the related character sets for this
      #   connection (connection, client, database, server, and results).
      # * :socket - Use a unix socket file instead of connecting via TCP/IP.
      # * :timeout - Set the timeout in seconds before the server will
      #   disconnect this connection.
      def connect(server)
        opts = server_opts(server)
        conn = ::Mysql2::Client.new({
          :host => opts[:host] || 'localhost',
          :username => opts[:user],
          :password => opts[:password],
          :database => opts[:database],
          :port => opts[:port],
          :socket => opts[:socket]
        })

        # increase timeout so mysql server doesn't disconnect us
        conn.query("set @@wait_timeout = #{opts[:timeout] || 2592000}")

        # By default, MySQL 'where id is null' selects the last inserted id
        conn.query("set SQL_AUTO_IS_NULL=0") unless opts[:auto_is_null]

        conn
      end

      # Returns instance of Sequel::MySQL::Dataset with the given options.
      def dataset(opts = nil)
        Mysql2::Dataset.new(self, opts)
      end

      # Executes the given SQL using an available connection, yielding the
      # connection if the block is given.
      def execute(sql, opts={}, &block)
        if opts[:sproc]
          call_sproc(sql, opts, &block)
        else
          synchronize(opts[:server]){|conn| _execute(conn, sql, opts, &block)}
        end
      end

      # Return the version of the MySQL server two which we are connecting.
      def server_version(server=nil)
        @server_version ||= (synchronize(server){|conn| conn.info[:id]})
      end

      private

      # Execute the given SQL on the given connection.  If the :type
      # option is :select, yield the result of the query, otherwise
      # yield the connection if a block is given.
      def _execute(conn, sql, opts)
        begin
          # r = log_yield(sql){conn.query(sql)}
          r = conn.query(sql)
          if opts[:type] == :select
            yield r if r
          elsif block_given?
            yield conn
          end
        rescue ::Mysql2::Error => e
          raise_error(e, :disconnect=>MYSQL_DATABASE_DISCONNECT_ERRORS.match(e.message))
        end
      end

      # MySQL connections use the query method to execute SQL without a result
      def connection_execute_method
        :query
      end

      # The MySQL adapter main error class is Mysql::Error
      def database_error_classes
        [::Mysql2::Error]
      end

      # The database name when using the native adapter is always stored in
      # the :database option.
      def database_name
        @opts[:database]
      end

      # Closes given database connection.
      def disconnect_connection(c)
        c.close
      end

      # Convert tinyint(1) type to boolean if convert_tinyint_to_bool is true
      def schema_column_type(db_type)
        Sequel::Mysql2.convert_tinyint_to_bool && db_type == 'tinyint(1)' ? :boolean : super
      end
    end

    # Dataset class for MySQL datasets accessed via the native driver.
    class Dataset < Sequel::Dataset
      include Sequel::MySQL::DatasetMethods
      include StoredProcedures

      # Methods for MySQL stored procedures using the native driver.
      module StoredProcedureMethods
        include Sequel::Dataset::StoredProcedureMethods

        private

        # Execute the database stored procedure with the stored arguments.
        def execute(sql, opts={}, &block)
          super(@sproc_name, {:args=>@sproc_args, :sproc=>true}.merge(opts), &block)
        end

        # Same as execute, explicit due to intricacies of alias and super.
        def execute_dui(sql, opts={}, &block)
          super(@sproc_name, {:args=>@sproc_args, :sproc=>true}.merge(opts), &block)
        end
      end

      # Delete rows matching this dataset
      def delete
        execute_dui(delete_sql){|c| return c.affected_rows}
      end

      # Yield all rows matching this dataset.  If the dataset is set to
      # split multiple statements, yield arrays of hashes one per statement
      # instead of yielding results for all statements as hashes.
      def fetch_rows(sql, &block)
        execute(sql) do |r|
          r.each &block
        end
        self
      end

      # Don't allow graphing a dataset that splits multiple statements
      def graph(*)
        raise(Error, "Can't graph a dataset that splits multiple result sets") if opts[:split_multiple_result_sets]
        super
      end

      # Insert a new value into this dataset
      def insert(*values)
        execute_dui(insert_sql(*values)){|c| return c.last_id}
      end

      # Replace (update or insert) the matching row.
      def replace(*args)
        execute_dui(replace_sql(*args)){|c| return c.last_id}
      end

      # Update the matching rows.
      def update(values={})
        execute_dui(update_sql(values)){|c| return c.affected_rows}
      end

      private

      # Set the :type option to :select if it hasn't been set.
      def execute(sql, opts={}, &block)
        super(sql, {:type=>:select}.merge(opts), &block)
      end

      # Set the :type option to :dui if it hasn't been set.
      def execute_dui(sql, opts={}, &block)
        super(sql, {:type=>:dui}.merge(opts), &block)
      end

      # Handle correct quoting of strings using ::Mysql2#escape.
      def literal_string(v)
        db.synchronize{|c| "'#{c.escape(v)}'"}
      end
    end
  end
end
