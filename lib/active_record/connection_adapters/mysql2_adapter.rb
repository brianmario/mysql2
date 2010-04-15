# encoding: utf-8

require 'mysql2' unless defined? Mysql2
require 'active_record/connection_adapters/mysql_adapter'

module ActiveRecord
  class Base
    def self.mysql2_connection(config)
      client = Mysql2::Client.new(config.symbolize_keys)
      options = [config[:host], config[:username], config[:password], config[:database], config[:port], config[:socket], 0]
      ConnectionAdapters::Mysql2Adapter.new(client, logger, options, config)
    end
  end

  module ConnectionAdapters
    class Mysql2Column < MysqlColumn
      # Returns the Ruby class that corresponds to the abstract data type.
      def klass
        case type
          when :integer       then Fixnum
          when :float         then Float
          when :decimal       then BigDecimal
          when :datetime      then Time
          when :date          then Time
          when :timestamp     then Time
          when :time          then Time
          when :text, :string then String
          when :binary        then String
          when :boolean       then Object
        end
      end

      def type_cast(value)
        if type == :boolean
          self.class.value_to_boolean(value)
        else
          value
        end
      end
      
      def type_cast_code(var_name)
        nil
      end
    end

    class Mysql2Adapter < MysqlAdapter
      PRIMARY = "PRIMARY".freeze

      # QUOTING ==================================================
      def quote_string(string)
        @connection.escape(string)
      end

      # CONNECTION MANAGEMENT ====================================

      def active?
        @connection.query 'select 1'
        true
      rescue Mysql2::Error
        false
      end

      def reconnect!
        reset!
      end

      def disconnect!
        @connection = nil
      end

      def reset!
        @connection = Mysql2::Client.new(@config)
      end

      # DATABASE STATEMENTS ======================================

      def select_values(sql, name = nil)
        result = select_rows(sql, name)
        result.map { |row| row.values.first }
      end

      def select_rows(sql, name = nil)
        select(sql, name)
      end

      def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        super sql, name
        id_value || @connection.last_id
      end
      alias :create :insert_sql

      # SCHEMA STATEMENTS ========================================

      def tables(name = nil)
        tables = []
        execute("SHOW TABLES", name).each(:symbolize_keys => true) do |field|
          tables << field.values.first
        end
        tables
      end

      def indexes(table_name, name = nil)
        indexes = []
        current_index = nil
        result = execute("SHOW KEYS FROM #{quote_table_name(table_name)}", name)
        result.each(:symbolize_keys => true) do |row|
          if current_index != row[:Key_name]
            next if row[:Key_name] == PRIMARY # skip the primary key
            current_index = row[:Key_name]
            indexes << IndexDefinition.new(row[:Table], row[:Key_name], row[:Non_unique] == 0, [])
          end

          indexes.last.columns << row[:Column_name]
        end
        indexes
      end

      def columns(table_name, name = nil)
        sql = "SHOW FIELDS FROM #{quote_table_name(table_name)}"
        columns = []
        result = execute(sql, :skip_logging)
        result.each(:symbolize_keys => true) { |field|
          columns << Mysql2Column.new(field[:Field], field[:Default], field[:Type], field[:Null] == "YES")
        }
        columns
      end

      def show_variable(name)
        variables = select_all("SHOW VARIABLES LIKE '#{name}'")
        variables.first[:Value] unless variables.empty?
      end

      def pk_and_sequence_for(table)
        keys = []
        result = execute("describe #{quote_table_name(table)}")
        result.each(:symbolize_keys) do |row|
          keys << row[:Field] if row[:Key] == "PRI"
        end
        keys.length == 1 ? [keys.first, nil] : nil
      end

      private
        def connect
          # no-op
        end

        def select(sql, name = nil)
          execute(sql, name).to_a
        end

        def supports_views?
          version[0] >= 5
        end

        def version
          @version ||= @connection.info[:version].scan(/^(\d+)\.(\d+)\.(\d+)/).flatten.map { |v| v.to_i }
        end
    end
  end
end