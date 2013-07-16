module Mysql2
  class Client
    attr_reader :query_options, :read_timeout
    @@default_query_options = {
      :as => :hash,                   # the type of object you want each row back as; also supports :array (an array of values)
      :async => false,                # don't wait for a result after sending the query, you'll have to monitor the socket yourself then eventually call Mysql2::Client#async_result
      :cast_booleans => false,        # cast tinyint(1) fields as true/false in ruby
      :symbolize_keys => false,       # return field names as symbols instead of strings
      :database_timezone => :local,   # timezone Mysql2 will assume datetime objects are stored in
      :application_timezone => nil,   # timezone Mysql2 will convert to before handing the object back to the caller
      :cache_rows => true,            # tells Mysql2 to use it's internal row cache for results
      :connect_flags => REMEMBER_OPTIONS | LONG_PASSWORD | LONG_FLAG | TRANSACTIONS | PROTOCOL_41 | SECURE_CONNECTION,
      :cast => true
    }

    def initialize(opts = {})
      opts = Mysql2::Util.key_hash_as_symbols( opts )
      @read_timeout = nil
      @query_options = @@default_query_options.dup
      @query_options.merge! opts

      initialize_ext

      # Set MySQL connection options (each one is a call to mysql_options())
      [:reconnect, :connect_timeout, :local_infile, :read_timeout, :write_timeout].each do |key|
        next unless opts.key?(key)
        case key
        when :reconnect, :local_infile
          send(:"#{key}=", !!opts[key])
        when :connect_timeout, :read_timeout, :write_timeout
          send(:"#{key}=", opts[key].to_i)
        else
          send(:"#{key}=", opts[key])
        end
      end

      # force the encoding to utf8
      self.charset_name = opts[:encoding] || 'utf8'

      ssl_options = opts.values_at(:sslkey, :sslcert, :sslca, :sslcapath, :sslcipher)
      ssl_set(*ssl_options) if ssl_options.any?

      if [:user,:pass,:hostname,:dbname,:db,:sock].any?{|k| @query_options.has_key?(k) }
        warn "============= WARNING FROM mysql2 ============="
        warn "The options :user, :pass, :hostname, :dbname, :db, and :sock will be deprecated at some point in the future."
        warn "Instead, please use :username, :password, :host, :port, :database, :socket, :flags for the options."
        warn "============= END WARNING FROM mysql2 ========="
      end

      user     = opts[:username] || opts[:user]
      pass     = opts[:password] || opts[:pass]
      host     = opts[:host] || opts[:hostname] || 'localhost'
      port     = opts[:port] || 3306
      database = opts[:database] || opts[:dbname] || opts[:db]
      socket   = opts[:socket] || opts[:sock]
      flags    = opts[:flags] ? opts[:flags] | @query_options[:connect_flags] : @query_options[:connect_flags]

      connect user, pass, host, port, database, socket, flags
    end

    def self.default_query_options
      @@default_query_options
    end

    def query_info
      info = query_info_string
      return {} unless info
      info_hash = {}
      info.split.each_slice(2) { |s| info_hash[s[0].downcase.delete(':').to_sym] = s[1].to_i }
      info_hash
    end

    private
      def self.local_offset
        ::Time.local(2010).utc_offset.to_r / 86400
      end
  end
end
