module Mysql2
  class Client
    attr_reader :connect_options, :query_options, :read_timeout

    VALID_CONNECT_KEYS = [:connect_flags, :connect_timeout, :encoding, :default_file, :default_group, :read_timeout, :write_timeout, :secure_auth, :init_command, :reconnect, :local_infile]
    @@default_connect_options = {
      :connect_flags   => REMEMBER_OPTIONS | LONG_PASSWORD | LONG_FLAG | TRANSACTIONS | PROTOCOL_41 | SECURE_CONNECTION,
      :connect_timeout => 120,        # Set default connect_timeout to avoid unlimited retries from signal interruption
      :encoding        => 'utf8'
    }

    VALID_QUERY_KEYS = [:as, :async, :cast_booleans, :symbolize_keys, :database_timezone, :application_timezone, :cache_rows, :cast]
    @@default_query_options = {
      :as                   => :hash,  # the type of object you want each row back as; also supports :array (an array of values)
      :async                => false,  # don't wait for a result after sending the query, you'll have to monitor the socket yourself then eventually call Mysql2::Client#async_result
      :cast_booleans        => false,  # cast tinyint(1) fields as true/false in ruby
      :symbolize_keys       => false,  # return field names as symbols instead of strings
      :database_timezone    => :local, # timezone Mysql2 will assume datetime objects are stored in
      :application_timezone => nil,    # timezone Mysql2 will convert to before handing the object back to the caller
      :cache_rows           => true,   # tells Mysql2 to use it's internal row cache for results
      :cast                 => true    # cast result fields to corresponding Ruby data types
    }

    def initialize(opts = {})
      opts = Mysql2::Util.key_hash_as_symbols(opts)
      @read_timeout = nil # by default don't timeout on read
      @connect_options = @@default_connect_options.merge Hash[ opts.select { |k, v| VALID_CONNECT_KEYS.include? k } ]
      @query_options = @@default_query_options.merge Hash[ opts.select { |k, v| VALID_QUERY_KEYS.include? k } ]

      initialize_ext

      [:reconnect, :connect_timeout, :local_infile, :read_timeout, :write_timeout, :default_file, :default_group, :secure_auth, :init_command].each do |key|
        next unless @connect_options.key?(key)
        case key
        when :reconnect, :local_infile, :secure_auth
          send(:"#{key}=", !!@connect_options[key])
        when :connect_timeout, :read_timeout, :write_timeout
          send(:"#{key}=", @connect_options[key].to_i)
        else
          send(:"#{key}=", @connect_options[key])
        end
      end

      # force the encoding to utf8 even if set to nil
      self.charset_name = @connect_options[:encoding] || 'utf8'

      ssl_options = opts.values_at(:sslkey, :sslcert, :sslca, :sslcapath, :sslcipher)
      ssl_set(*ssl_options) if ssl_options.any?

      if [:user, :pass, :hostname, :dbname, :db, :sock].any? { |k| @connect_options.has_key? k }
        raise <<-DEPR
The options :user, :pass, :hostname, :dbname, :db, :sock are removed.
Please use :username, :password, :host, :port, :database, :socket instead.
DEPR
      end

      # Correct the data types before passing these values down to the C level
      user     = opts[:username].to_s unless opts[:username].nil?
      pass     = opts[:password].to_s unless opts[:password].nil?
      host     = opts[:host].to_s     unless opts[:host].nil?
      port     = opts[:port].to_i     unless opts[:port].nil?
      database = opts[:database].to_s unless opts[:database].nil?
      socket   = opts[:socket].to_s   unless opts[:socket].nil?
      flags    = opts[:flags] ? opts[:flags] | @connect_options[:connect_flags] : @connect_options[:connect_flags]
      flags  ||= 0 # if nil then 0

      connect user, pass, host, port, database, socket, flags
    end

    def self.default_connect_options
      @@default_connect_options
    end

    def self.default_query_options
      @@default_query_options
    end

    if Thread.respond_to?(:handle_interrupt)
      def query(sql, options = {})
        Thread.handle_interrupt(Timeout::ExitException => :never) do
          _query(sql, @query_options.merge(options))
        end
      end
    else
      def query(sql, options = {})
        _query(sql, @query_options.merge(options))
      end
    end

    def query_info
      info = query_info_string
      return {} unless info
      info_hash = {}
      info.split.each_slice(2) { |s| info_hash[s[0].downcase.delete(':').to_sym] = s[1].to_i }
      info_hash
    end

    def info
      self.class.info
    end

    private
      def self.local_offset
        ::Time.local(2010).utc_offset.to_r / 86400
      end
  end
end
