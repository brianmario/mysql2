module Mysql2
  class Client
    attr_reader :query_options, :read_timeout

    def self.default_query_options
      @default_query_options ||= {
        as: :hash,                   # the type of object you want each row back as; also supports :array (an array of values) and :splat (yields each row's values as block arguments, no per-row container)
        async: false,                # don't wait for a result after sending the query, you'll have to monitor the socket yourself then eventually call Mysql2::Client#async_result
        cast_booleans: false,        # cast tinyint(1) fields as true/false in ruby
        symbolize_keys: false,       # return field names as symbols instead of strings
        database_timezone: :local,   # timezone Mysql2 will assume datetime objects are stored in
        application_timezone: nil,   # timezone Mysql2 will convert to before handing the object back to the caller
        cache_rows: true,            # tells Mysql2 to use its internal row cache for results
        rows_per_gvl_yield: 8192,    # buffered rows to materialize between GVL yields; 0 disables yielding
        connect_flags: REMEMBER_OPTIONS | LONG_PASSWORD | LONG_FLAG | TRANSACTIONS | PROTOCOL_41 | SECURE_CONNECTION | CONNECT_ATTRS,
        cast: true,
        default_file: nil,
        default_group: nil,
      }
    end

    # :tls_key/:tls_cert/:tls_ca/:tls_capath/:tls_cipher are the modern names
    # for :sslkey/:sslcert/:sslca/:sslcapath/:sslcipher. MariaDB Connector/C
    # registers both spellings for its own equivalent option-file settings
    # (ssl-key and tls-key, ssl-passphrase and tls-passphrase, etc.); mysql2
    # follows the same pattern here. If both spellings are given, the newer
    # :tls_* name wins -- the same precedence an explicit :ssl_mode already
    # has over :sslverify.
    #
    # :tls_mode/:ssl_mode is different: neither MySQL nor MariaDB has a
    # "tls-mode" config-file alias for ssl-mode anywhere -- this one is
    # mysql2's own invention, purely for :tls_* naming consistency. If
    # upstream ever adds a real --tls-mode/tlsMode with different
    # semantics, this alias becomes wrong and will need to be revisited.
    TLS_OPTION_ALIASES = {
      tls_key: :sslkey,
      tls_cert: :sslcert,
      tls_ca: :sslca,
      tls_capath: :sslcapath,
      tls_cipher: :sslcipher,
      tls_mode: :ssl_mode,
    }.freeze
    private_constant :TLS_OPTION_ALIASES

    def initialize(opts = {})
      raise Mysql2::Error, "Options parameter must be a Hash" unless opts.is_a? Hash

      opts = Mysql2::Util.key_hash_as_symbols(opts)
      @read_timeout = nil
      @query_options = self.class.default_query_options.dup
      @query_options.merge! opts

      apply_tls_option_aliases(opts)

      initialize_ext

      # Set default connect_timeout to avoid unlimited retries from signal interruption
      opts[:connect_timeout] = 120 unless opts.key?(:connect_timeout)

      # TODO: stricter validation rather than silent massaging
      %i[reconnect connect_timeout local_infile read_timeout write_timeout default_file default_group secure_auth init_command automatic_close enable_cleartext_plugin default_auth get_server_public_key tls_version].each do |key|
        next unless opts.key?(key)

        case key
        when :reconnect, :local_infile, :secure_auth, :automatic_close, :enable_cleartext_plugin, :get_server_public_key
          send(:"#{key}=", !!opts[key]) # rubocop:disable Style/DoubleNegation
        when :connect_timeout, :read_timeout, :write_timeout
          send(:"#{key}=", Integer(opts[key])) unless opts[key].nil?
        else
          send(:"#{key}=", opts[key])
        end
      end

      # force the encoding to utf8mb4
      self.charset_name = opts[:encoding] || 'utf8mb4'

      mode = parse_ssl_mode(opts[:ssl_mode]) if opts[:ssl_mode]
      mode = configure_tls_verification(opts, mode)

      ssl_options = opts.values_at(:sslkey, :sslcert, :sslca, :sslcapath, :sslcipher)
      ssl_set(*ssl_options) if ssl_options.any? || opts.key?(:sslverify)
      self.ssl_mode = mode if mode

      flags = case opts[:flags]
      when Array
        parse_flags_array(opts[:flags], @query_options[:connect_flags])
      when String
        parse_flags_array(opts[:flags].split(' '), @query_options[:connect_flags])
      when Integer
        @query_options[:connect_flags] | opts[:flags]
      else
        @query_options[:connect_flags]
      end

      # SSL verify is a connection flag rather than a mysql_ssl_set option
      flags |= SSL_VERIFY_SERVER_CERT if opts[:sslverify]

      check_and_clean_query_options

      user         = opts[:username] || opts[:user]
      pass         = opts[:password] || opts[:pass]
      host         = opts[:host] || opts[:hostname]
      port         = opts[:port]
      database     = opts[:database] || opts[:dbname] || opts[:db]
      socket       = opts[:socket] || opts[:sock]
      tls_sni_name = opts[:tls_sni_name]

      # Correct the data types before passing these values down to the C level
      user = user.to_s unless user.nil?
      pass = pass.to_s unless pass.nil?
      host = host.to_s unless host.nil?
      port = port.to_i unless port.nil?
      database = database.to_s unless database.nil?
      socket = socket.to_s unless socket.nil?
      tls_sni_name = tls_sni_name.to_s unless tls_sni_name.nil?
      conn_attrs = parse_connect_attrs(opts[:connect_attrs])

      connect user, pass, host, port, database, socket, flags, conn_attrs, tls_sni_name
    end

    def parse_ssl_mode(mode)
      m = mode.to_s.upcase
      if m.start_with?('SSL_MODE_')
        return Mysql2::Client.const_get(m) if Mysql2::Client.const_defined?(m)
      else
        x = 'SSL_MODE_' + m
        return Mysql2::Client.const_get(x) if Mysql2::Client.const_defined?(x)
      end
      warn "Unknown MySQL ssl_mode flag: #{mode}"
    end

    def parse_flags_array(flags, initial = 0)
      flags.reduce(initial) do |memo, f|
        fneg = f.start_with?('-') ? f[1..-1] : nil
        if fneg && fneg =~ /^\w+$/ && Mysql2::Client.const_defined?(fneg)
          memo & ~ Mysql2::Client.const_get(fneg)
        elsif f && f =~ /^\w+$/ && Mysql2::Client.const_defined?(f)
          memo | Mysql2::Client.const_get(f)
        else
          warn "Unknown MySQL connection flag: '#{f}'"
          memo
        end
      end
    end

    # Enforce the coherence of the TLS verification options before any of
    # them reach the client library, so a verification the caller asked for
    # can never be silently skipped (the #879 failure mode). Also maps the
    # legacy :sslverify boolean onto :ssl_mode, and returns the effective
    # mode -- possibly filled in from :sslverify -- for the caller to apply.
    #
    # :sslca/:sslcapath left unset means the TLS backend resolves its default
    # trust store natively (OpenSSL's default verify paths,
    # SSL_CERT_FILE/SSL_CERT_DIR, or the platform certificate store). Whether
    # verification actually succeeded is proven at connect time -- the
    # verification callback and the post-connect tripwire fail closed on any
    # connection whose chain or hostname cannot be shown verified.
    def configure_tls_verification(opts, mode)
      # The mode != 0 guard keeps ancient no-ssl_mode builds (where every
      # SSL_MODE_* constant collapses to 0) out of the verify-tier handling.
      verify_mode = (mode == SSL_MODE_VERIFY_CA || mode == SSL_MODE_VERIFY_IDENTITY) && mode != 0

      if opts.key?(:sslverify)
        if opts[:sslverify]
          # :sslverify => true is the legacy spelling of ssl_mode: :verify_identity
          # -- MYSQL_OPT_SSL_MODE's own VERIFY_IDENTITY handler sets the same
          # CLIENT_SSL_VERIFY_SERVER_CERT connect-flag :sslverify sets directly
          # (still below, unconditionally). An explicit :ssl_mode always wins;
          # this only fills in a mode the caller didn't otherwise ask for, and
          # only where SSL_MODE_VERIFY_IDENTITY is a real, enforceable value.
          if (mode.nil? || mode.zero?) && !SSL_MODE_VERIFY_IDENTITY.zero?
            mode = SSL_MODE_VERIFY_IDENTITY
            verify_mode = true
          end
        elsif verify_mode
          # :sslverify => false and a verifying ssl_mode contradict each
          # other: one says the connection doesn't need to be verified, the
          # other asks mysql2 to refuse it unless it is. Refuse the ambiguity
          # instead of silently picking a side.
          raise Mysql2::Error::ConnectionError, "sslverify: false conflicts with ssl_mode: #{opts[:ssl_mode]}"
        end
      end

      # Unlocks an encrypted :sslkey file -- unrelated to the verification
      # models below, so set unconditionally rather than gated on them.
      self.tls_passphrase = opts[:tls_passphrase].to_s if opts[:tls_passphrase]

      return mode unless opts[:tls_peer_fingerprint] || opts[:tls_peer_fingerprint_list]

      # Fingerprint pinning and CA/hostname verification are alternative
      # trust models in MariaDB Connector/C: a pinned connection runs the
      # FINGERPRINT check instead of the HOST/TRUST checks, so combining
      # them would silently drop whichever one loses. Refuse the ambiguity.
      raise Mysql2::Error::ConnectionError, ":tls_peer_fingerprint pinning and ssl_mode: #{opts[:ssl_mode]} are mutually exclusive verification models; pick one" \
        if verify_mode

      self.tls_peer_fingerprint = opts[:tls_peer_fingerprint].to_s if opts[:tls_peer_fingerprint]
      self.tls_peer_fingerprint_list = opts[:tls_peer_fingerprint_list].to_s if opts[:tls_peer_fingerprint_list]

      mode
    end

    # Find any default system CA paths to handle system roots
    # by default if stricter validation is requested and no
    # path is provide.
    def find_default_ca_path
      [
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
        "/etc/ssl/cert.pem",
      ].find { |f| File.exist?(f) }
    end

    # Set default program_name in performance_schema.session_connect_attrs
    # and performance_schema.session_account_connect_attrs
    def parse_connect_attrs(conn_attrs)
      return {} if Mysql2::Client::CONNECT_ATTRS.zero?

      conn_attrs ||= {}
      conn_attrs[:program_name] ||= $PROGRAM_NAME
      conn_attrs.each_with_object({}) do |(key, value), hash|
        hash[key.to_s] = value.to_s
      end
    end

    # Shared frozen default for the options argument, so the no-options case
    # skips allocating a fresh empty hash per call. The merge itself is
    # unchanged: it still produces the per-query snapshot the C extension
    # retains as @current_query_options, and explicit-but-invalid arguments
    # like nil or false still raise TypeError from Hash#merge as they
    # always have.
    EMPTY_QUERY_OPTIONS = {}.freeze
    private_constant :EMPTY_QUERY_OPTIONS

    def query(sql, options = EMPTY_QUERY_OPTIONS)
      Thread.handle_interrupt(::Mysql2::Util::TIMEOUT_ERROR_NEVER) do
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

    def apply_tls_option_aliases(opts)
      TLS_OPTION_ALIASES.each { |tls_key, legacy_key| opts[legacy_key] = opts[tls_key] if opts.key?(tls_key) }
    end

    # Warns once per client, before connecting, about option combinations
    # that are incoherent or silently ignored. Warnings only: the connection
    # proceeds exactly as it would have without them.
    def warn_incoherent_options
      # The client key and certificate only take effect together. Given one
      # without the other, libmysqlclient silently sends no client certificate
      # and MariaDB Connector/C aborts the connection with a bare TLS error
      # that never names the real problem. Either option may be given under
      # its legacy :ssl* name or its :tls_* alias.
      # https://dev.mysql.com/doc/refman/en/using-encrypted-connections.html
      effective_key = @query_options[:tls_key] || @query_options[:sslkey]
      effective_cert = @query_options[:tls_cert] || @query_options[:sslcert]
      warn ":sslkey and :sslcert only take effect together; alone, libmysqlclient sends no client certificate and MariaDB Connector/C fails to connect" \
        if effective_key.nil? != effective_cert.nil?

      # If a legacy :ssl* option and its :tls_* alias are both given with
      # different values, the :tls_* value silently wins (see
      # TLS_OPTION_ALIASES); warn so the conflict isn't invisible.
      TLS_OPTION_ALIASES.each do |tls_key, legacy_key|
        next unless @query_options.key?(tls_key) && @query_options.key?(legacy_key)
        next if @query_options[tls_key] == @query_options[legacy_key]

        warn ":#{legacy_key} and :#{tls_key} were both given with different values; :#{tls_key} wins"
      end

      # Streaming results are never cached, so a client-wide :stream default
      # overrides the :cache_rows default on every query (see the per-query
      # warning in ext/mysql2/result.c).
      warn ":cache_rows is ignored on a client with :stream enabled; pass cache_rows: false to acknowledge streaming semantics" \
        if @query_options[:stream] && @query_options[:cache_rows]
    end

    def check_and_clean_query_options
      warn_incoherent_options

      if %i[user pass hostname dbname db sock].any? { |k| @query_options.key?(k) }
        warn "============= WARNING FROM mysql2 ============="
        warn "The options :user, :pass, :hostname, :dbname, :db, and :sock are deprecated and will be removed at some point in the future."
        warn "Instead, please use :username, :password, :host, :port, :database, :socket, :flags for the options."
        warn "============= END WARNING FROM mysql2 ========="
      end

      # avoid logging sensitive data via #inspect
      @query_options.delete(:password)
      @query_options.delete(:pass)
    end

    class << self
      private

      def local_offset
        ::Time.local(2010).utc_offset.to_r / 86400
      end
    end
  end
end
