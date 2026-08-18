require 'spec_helper'
require 'socket'

RSpec.describe Mysql2::Client do # rubocop:disable Metrics/BlockLength
  let(:performance_schema_enabled) do
    performance_schema = @client.query "SHOW VARIABLES LIKE 'performance_schema'"
    performance_schema.any? { |x| x['Value'] == 'ON' }
  end

  context "using defaults file" do
    let(:cnf_file) { File.expand_path('../../my.cnf', __FILE__) }

    it "should not raise an exception for valid defaults group" do
      expect do
        new_client(default_file: cnf_file, default_group: "test")
      end.not_to raise_error
    end

    it "should not raise an exception without default group" do
      expect do
        new_client(default_file: cnf_file)
      end.not_to raise_error
    end
  end

  it "should raise a Mysql::Error::ConnectionError upon connection failure" do
    expect do
      # The odd local host IP address forces the mysql client library to
      # use a TCP socket rather than a domain socket.
      new_client('host' => '127.0.0.2', 'port' => 999999)
    end.to raise_error(Mysql2::Error::ConnectionError)
  end

  it "should connect over a Unix socket" do
    client = new_socket_client
    expect(client.query("SELECT 1 AS one").first).to eq("one" => 1)
  end

  it "should connect via TLS" do
    # have_ssl was removed in newer MySQL (SSL is unconditionally compiled
    # in there); an empty result set means "assume available", matching the
    # "context SSL" before(:example) hook's own fallback below.
    ssl_disabled = @client.query("SHOW VARIABLES LIKE 'have_ssl'").any? { |x| %w[OFF DISABLED].include?(x['Value']) }
    skip("DON'T WORRY, THIS TEST PASSES - but SSL is not enabled in your MySQL daemon.") if ssl_disabled

    client = new_client(ssl_mode: 'required')
    expect(client.ssl_cipher).not_to be_empty
  end

  it "should raise an exception on create for invalid encodings" do
    expect do
      new_client(encoding: "fake")
    end.to raise_error(Mysql2::Error)
  end

  it "should raise an exception on non-string encodings" do
    expect do
      new_client(encoding: :fake)
    end.to raise_error(TypeError)
  end

  it "should not raise an exception on create for a valid encoding" do
    expect do
      new_client(encoding: "utf8")
    end.not_to raise_error

    expect do
      new_client(DatabaseCredentials['root'].merge(encoding: "big5"))
    end.not_to raise_error
  end

  Klient = Class.new(Mysql2::Client) do
    attr_reader :connect_args

    def connect(*args)
      @connect_args ||= []
      @connect_args << args
    end
  end

  it "should accept connect flags and pass them to #connect" do
    client = Klient.new flags: Mysql2::Client::FOUND_ROWS
    expect(client.connect_args.last[6] & Mysql2::Client::FOUND_ROWS).to be > 0
  end

  it "should parse flags array" do
    client = Klient.new flags: %w[FOUND_ROWS -PROTOCOL_41]
    expect(client.connect_args.last[6] & Mysql2::Client::FOUND_ROWS).to eql(Mysql2::Client::FOUND_ROWS)
    expect(client.connect_args.last[6] & Mysql2::Client::PROTOCOL_41).to eql(0)
  end

  it "should parse flags string" do
    client = Klient.new flags: "FOUND_ROWS -PROTOCOL_41"
    expect(client.connect_args.last[6] & Mysql2::Client::FOUND_ROWS).to eql(Mysql2::Client::FOUND_ROWS)
    expect(client.connect_args.last[6] & Mysql2::Client::PROTOCOL_41).to eql(0)
  end

  it "should default flags to (REMEMBER_OPTIONS, LONG_PASSWORD, LONG_FLAG, TRANSACTIONS, PROTOCOL_41, SECURE_CONNECTION)" do
    client = Klient.new
    client_flags = Mysql2::Client::REMEMBER_OPTIONS |
                   Mysql2::Client::LONG_PASSWORD |
                   Mysql2::Client::LONG_FLAG |
                   Mysql2::Client::TRANSACTIONS |
                   Mysql2::Client::PROTOCOL_41 |
                   Mysql2::Client::SECURE_CONNECTION |
                   Mysql2::Client::CONNECT_ATTRS
    expect(client.connect_args.last[6]).to eql(client_flags)
  end

  it "should execute init command" do
    options = DatabaseCredentials['root'].dup
    options[:init_command] = "SET @something = 'setting_value';"
    client = new_client(options)
    result = client.query("SELECT @something;")
    expect(result.first['@something']).to eq('setting_value')
  end

  it "should send init_command after reconnect" do
    options = DatabaseCredentials['root'].dup
    options[:init_command] = "SET @something = 'setting_value';"
    options[:reconnect] = true
    client = new_client(options)

    result = client.query("SELECT @something;")
    expect(result.first['@something']).to eq('setting_value')

    # get the current connection id
    result = client.query("SELECT CONNECTION_ID()")
    first_conn_id = result.first['CONNECTION_ID()']

    # break the current connection
    expect { client.query("KILL #{first_conn_id}") }.to raise_error(Mysql2::Error)

    client.ping # reconnect now

    # get the new connection id
    result = client.query("SELECT CONNECTION_ID()")
    second_conn_id = result.first['CONNECTION_ID()']

    # confirm reconnect by checking the new connection id
    expect(first_conn_id).not_to eq(second_conn_id)

    # At last, check that the init command executed
    result = client.query("SELECT @something;")
    expect(result.first['@something']).to eq('setting_value')
  end

  it "should have a global default_query_options hash" do
    expect(Mysql2::Client).to respond_to(:default_query_options)
  end

  context "SSL" do
    before(:example) do
      ssl = @client.query "SHOW VARIABLES LIKE 'have_ssl'"
      ssl_uncompiled = ssl.any? { |x| x['Value'] == 'OFF' }
      ssl_disabled = ssl.any? { |x| x['Value'] == 'DISABLED' }
      if ssl_uncompiled
        skip("DON'T WORRY, THIS TEST PASSES - but SSL is not compiled into your MySQL daemon.")
      elsif ssl_disabled
        skip("DON'T WORRY, THIS TEST PASSES - but SSL is not enabled in your MySQL daemon.")
      else
        %i[sslkey sslcert sslca].each do |item|
          unless File.exist?(option_overrides[item])
            skip("DON'T WORRY, THIS TEST PASSES - but #{option_overrides[item]} does not exist.")
            break
          end
        end
      end
    end

    let(:option_overrides) do
      {
        'host'     => ssl_cert_host, # must match the certificates
        :sslkey    => "#{ssl_cert_dir}/client-key.pem",
        :sslcert   => "#{ssl_cert_dir}/client-cert.pem",
        :sslca     => "#{ssl_cert_dir}/ca-cert.pem",
        :sslcipher => 'DHE-RSA-AES256-SHA',
        :sslverify => true,
      }
    end

    let(:ssl_client) do
      new_client(option_overrides)
    end

    # 'preferred' is only in MySQL 5.6.36+, 5.7.11+, 8.0+ -- MariaDB Connector/C
    # has no equivalent option, so mysql2 can't do anything for it there.
    # 'verify_ca' works everywhere: on MariaDB Connector/C it maps to
    # MYSQL_OPT_SSL_VERIFY_SERVER_CERT, which is CA verification at most --
    # the connector never checks the hostname for local peers (#879).
    # 'verify_identity' maps to the same option plus mysql2's own
    # verification callback, which makes the hostname check real.
    #
    # The upper bound on the first range stops at 100000 (not left unbounded)
    # because MariaDB's client version numbering starts there (10.x =
    # 100000+, 11.x = 110000+, 12.x = 120000+) and MariaDB has never
    # implemented the 5-value ssl_mode API that range is testing -- see
    # FULL_SSL_MODE_SUPPORT in extconf.rb and rb_set_ssl_mode_option's own
    # version >= 100000 MariaDB check.
    version = Mysql2::Client.info[:id]
    ssl_modes = case version
    when 50636...50700, 50711...50800, 80000...100000
      %i[disabled preferred required verify_ca verify_identity]
    else
      %i[disabled required verify_ca verify_identity]
    end

    # On MariaDB-family builds without the enforcement callback,
    # :verify_identity refuses to connect rather than silently skipping the
    # hostname check -- the "refuses verify_identity outright" spec under
    # TLS option validation covers that refusal.
    mysql_native_verify = (50703...50711).cover?(version) || (60103...60200).cover?(version)
    verify_identity_unenforceable = version >= 30000 && !mysql_native_verify && Mysql2::Client::TLS_PEER_IDENTITY_VERIFICATION.nil?

    # MySQL and MariaDB and all versions of Connector/C
    ssl_modes.each do |ssl_mode|
      it "should set ssl_mode option #{ssl_mode}" do
        skip "this build refuses verify_identity rather than skipping the hostname check (#879)" \
          if ssl_mode == :verify_identity && verify_identity_unenforceable

        options = {
          ssl_mode: ssl_mode,
        }
        options.merge!(option_overrides)
        expect do
          expect do
            new_client(options)
          end.not_to output(/does not support ssl_mode/).to_stderr
        end.not_to raise_error
      end
    end

    it "should reject a connection when ssl_mode is verify_ca and the CA doesn't match the server's" do
      require 'openssl'
      require 'tempfile'

      wrong_ca_key = OpenSSL::PKey::RSA.new(2048)
      wrong_ca_cert = OpenSSL::X509::Certificate.new
      wrong_ca_cert.version = 2
      wrong_ca_cert.serial = 1
      wrong_ca_cert.subject = OpenSSL::X509::Name.parse('/CN=wrong-ca')
      wrong_ca_cert.issuer = wrong_ca_cert.subject
      wrong_ca_cert.public_key = wrong_ca_key.public_key
      wrong_ca_cert.not_before = Time.now
      wrong_ca_cert.not_after = Time.now + 3600
      wrong_ca_cert.sign(wrong_ca_key, OpenSSL::Digest.new('SHA256'))

      Tempfile.create(['wrong-ca', '.pem']) do |f|
        f.write(wrong_ca_cert.to_pem)
        f.flush

        options = option_overrides.merge(ssl_mode: :verify_ca, sslca: f.path)
        expect { new_client(options) }.to raise_error(Mysql2::Error)
      end
    end

    it "should be able to connect via SSL options" do
      # You may need to adjust the lines below to match your SSL certificate paths
      results = Hash[ssl_client.query('SHOW STATUS WHERE Variable_name LIKE "Ssl_%"').map { |x| x.values_at('Variable_name', 'Value') }]
      expect(results['Ssl_cipher']).not_to be_empty
      expect(results['Ssl_version']).not_to be_empty

      expect(ssl_client.ssl_cipher).not_to be_empty
      expect(results['Ssl_cipher']).to eql(ssl_client.ssl_cipher)
    end

    context "peer identity verification (#879)" do
      # The server certificate's CN is ssl_cert_host (mysql2gem.example.com,
      # no SAN extension), and CI's /etc/hosts aliases both that name and
      # ssl_cert_wrong_host to 127.0.0.1 -- so every leg below reaches the
      # identical server, differing only in the hostname the certificate is
      # checked against.
      let(:verification) { Mysql2::Client::TLS_PEER_IDENTITY_VERIFICATION }

      it "accepts verify_identity when the hostname matches the server certificate" do
        skip "verify_identity is not enforceable on this build" if verification.nil?

        new_client(option_overrides.merge(ssl_mode: :verify_identity)) do |client|
          expect(client.query('SELECT 1 AS one').first['one']).to eql(1)
        end
      end

      it "proves via tls_info which verification rung ran" do
        skip "requires mysql2's callback enforcement (MariaDB Connector/C 3.4+ build)" unless verification == :callback

        new_client(option_overrides.merge(ssl_mode: :verify_identity)) do |client|
          info = client.tls_info
          expect(info[:identity_verified]).to be true
          expect(info[:verify_status]).to eql(0)
        end
      end

      it "rejects verify_identity connecting by an IP address the certificate does not cover" do
        # The #879 regression leg: the connector's default verifier decides
        # which checks run from the peer address and classifies 127.0.0.1 as
        # local, skipping hostname verification entirely -- before mysql2's
        # callback enforcement this connection SUCCEEDED with the server's
        # identity never verified.
        options = option_overrides.merge(ssl_mode: :verify_identity, 'host' => '127.0.0.1')
        if verification == :callback
          expect { new_client(options) }.to raise_error(Mysql2::Error::ConnectionError, /verify_identity.+(certificate|hostname)/i)
        else
          # :native (libmysqlclient) refuses with its own error message; a
          # build that cannot enforce refuses at Client.new instead of
          # silently degrading.
          expect { new_client(options) }.to raise_error(Mysql2::Error::ConnectionError)
        end
      end

      it "fails closed at connect time, not Client.new, when no CA is configured" do
        skip "verify_identity is not enforceable on this build" if verification.nil?

        # Unset :sslca/:sslcapath is not pre-flighted in Ruby: the TLS
        # backend resolves its default trust store natively, and the connect
        # attempt is the source of truth. The suite's CA never appears in a
        # system trust store, so the chain cannot verify -- enforcement (the
        # verification callback and the post-connect tripwire) must refuse
        # the connection rather than fall through to the connector's no-CA
        # self-signed leniency.
        options = option_overrides.reject { |k, _| k.to_s.start_with?("sslca") }.merge(ssl_mode: :verify_identity)
        expect { new_client(options) }.to raise_error(Mysql2::Error::ConnectionError, /SSL|TLS|certificate/i)
      end

      it "rejects verify_identity connecting by a hostname the certificate does not cover" do
        require 'resolv'
        begin
          Resolv.getaddress(ssl_cert_wrong_host)
        rescue Resolv::ResolvError
          skip("DON'T WORRY, THIS TEST PASSES - but #{ssl_cert_wrong_host} does not resolve here. Alias it to the database server (as CI does in /etc/hosts) to run this leg.")
        end

        # Guards the by-name topology: a non-local peer name gets the
        # HOST/TRUST checks even from the connector's own default verifier,
        # and must stay refused under mysql2's callback too.
        options = option_overrides.merge(ssl_mode: :verify_identity, 'host' => ssl_cert_wrong_host)
        expect { new_client(options) }.to raise_error(Mysql2::Error::ConnectionError)
      end
    end

    context "Client#tls_info" do
      it "describes the TLS session" do
        info = ssl_client.tls_info

        # Introspection ships with the same Connector/C 3.4 surface the
        # callback enforcement builds against, so :callback builds must
        # return a hash here; :native (libmysqlclient) has no introspection
        # API and always returns nil.
        expect(info).to be_a(Hash) if Mysql2::Client::TLS_PEER_IDENTITY_VERIFICATION == :callback
        skip "tls_info introspection is not available on this build" if info.nil?

        expect(info[:tls_version]).to match(/TLS/i)
        expect(info[:cipher]).not_to be_empty
        expect(info[:verify_status]).to eql(0)
        expect(info[:identity_verified]).to be false # no :verify_identity requested
        expect(info[:peer_cert][:subject]).to include(ssl_cert_host)
        expect(info[:peer_cert][:issuer]).not_to be_empty
        expect(info[:peer_cert][:fingerprint]).to match(/\A\h{64}\z/)
        expect(info[:peer_cert][:not_after]).to be > info[:peer_cert][:not_before]
      end

      it "is nil when the connection does not use TLS" do
        new_client(ssl_mode: :disabled) do |client|
          expect(client.tls_info).to be_nil
        end
      end
    end

    context "certificate fingerprint pinning" do
      let(:server_cert_fingerprint) do
        require 'openssl'
        OpenSSL::Digest::SHA256.hexdigest(OpenSSL::X509::Certificate.new(File.read("#{ssl_cert_dir}/server-cert.pem")).to_der)
      end

      it "connects CA-less when the server certificate matches the pinned fingerprint" do
        skip "fingerprint pinning is not supported by this client library build" unless Mysql2::Client::TLS_PEER_FINGERPRINT_SUPPORTED

        new_client(tls_peer_fingerprint: server_cert_fingerprint) do |client|
          expect(client.query('SELECT 1 AS one').first['one']).to eql(1)
          info = client.tls_info
          next if info.nil?

          # Pinning is its own verification rung: the fingerprint matched,
          # the hostname rung deliberately did not run, and with no CA
          # configured the connector records the chain as untrusted
          # (TLS_VERIFY_TRUST) even though the pin -- not the chain -- is
          # this connection's trust anchor. Anything beyond that bit would
          # mean a check we do care about failed.
          expect(info[:verify_status] & ~Mysql2::Client::TLS_VERIFY_TRUST).to eql(0)
          expect(info[:identity_verified]).to be false
          expect(info[:peer_cert][:fingerprint].downcase).to eql(server_cert_fingerprint.downcase)
        end
      end

      it "refuses when the server certificate does not match the pinned fingerprint" do
        skip "fingerprint pinning is not supported by this client library build" unless Mysql2::Client::TLS_PEER_FINGERPRINT_SUPPORTED

        expect do
          new_client(tls_peer_fingerprint: server_cert_fingerprint.reverse)
        end.to raise_error(Mysql2::Error, /[Ff]ingerprint/)
      end
    end

    it "should negotiate the requested tls_version" do
      skip("DON'T WORRY, THIS TEST PASSES - but this client library does not support tls_version.") unless Mysql2::Client::TLS_VERSION_SUPPORTED

      # option_overrides' :sslcipher is a TLS 1.2-only cipher name (TLS 1.3
      # negotiates ciphersuites through a separate mechanism entirely --
      # MYSQL_OPT_TLS_CIPHERSUITES, which mysql2 doesn't set). Forcing that
      # legacy cipher while also restricting to tls_version: 'TLSv1.3' is a
      # real, self-inflicted handshake failure, not a tls_version bug -- drop
      # it here and let the library pick its own default cipher per version.
      tls_options = option_overrides.reject { |k, _| k == :sslcipher }

      %w[TLSv1.2 TLSv1.3].each do |version|
        client = new_client(tls_options.merge(tls_version: version))
        result = client.query("SHOW STATUS LIKE 'Ssl_version'").first
        expect(result['Value']).to eq(version)
      end
    end

    it "should raise when the tls_version option is unsupported" do
      skip("DON'T WORRY, THIS TEST PASSES - but this client library supports tls_version.") if Mysql2::Client::TLS_VERSION_SUPPORTED

      expect do
        new_client(option_overrides.merge(tls_version: 'TLSv1.2'))
      end.to raise_error(Mysql2::Error, /tls_version/)
    end

    context "legacy :ssl* / :tls_* option aliasing" do
      it "connects the same using :tls_key/:tls_cert/:tls_ca as with :sslkey/:sslcert/:sslca" do
        aliased_overrides = option_overrides
                            .reject { |k, _| %i[sslkey sslcert sslca].include?(k) }
                            .merge(
                              tls_key: option_overrides[:sslkey],
                              tls_cert: option_overrides[:sslcert],
                              tls_ca: option_overrides[:sslca],
                            )

        new_client(aliased_overrides) do |client|
          expect(client.query('SELECT 1 AS one').first['one']).to eql(1)
        end
      end

      it "connects the same using :tls_mode as with :ssl_mode" do
        aliased_overrides = option_overrides.merge(tls_mode: :required).reject { |k, _| k == :sslverify }

        new_client(aliased_overrides) do |client|
          expect(client.query('SELECT 1 AS one').first['one']).to eql(1)
        end
      end
    end
  end

  context "option coherence warnings" do
    it "warns when :sslkey is given without :sslcert" do
      expect do
        begin
          new_client(sslkey: '/path/to/client-key.pem')
        rescue Mysql2::Error
          # MariaDB Connector/C rejects a lone key at connect; the warning precedes it.
        end
      end.to output(/:sslkey and :sslcert only take effect together/).to_stderr
    end

    it "warns when :sslcert is given without :sslkey" do
      expect do
        begin
          new_client(sslcert: '/path/to/client-cert.pem')
        rescue Mysql2::Error
          # MariaDB Connector/C rejects a lone certificate at connect; the warning precedes it.
        end
      end.to output(/:sslkey and :sslcert only take effect together/).to_stderr
    end

    it "warns when :stream is enabled with :cache_rows left on" do
      expect do
        new_client(stream: true)
      end.to output(/:cache_rows is ignored on a client with :stream enabled/).to_stderr
    end

    it "does not warn when :stream is enabled with :cache_rows disabled" do
      expect do
        new_client(stream: true, cache_rows: false)
      end.not_to output(/:cache_rows is ignored/).to_stderr
    end

    it "does not warn on a plain connection" do
      expect do
        new_client
      end.not_to output(/:sslkey and :sslcert only take effect together|:cache_rows is ignored/).to_stderr
    end

    it "warns when a legacy :ssl* option and its :tls_* alias are given with different values" do
      expect do
        begin
          new_client(sslkey: '/path/to/legacy-key.pem', tls_key: '/path/to/new-key.pem', tls_cert: '/path/to/client-cert.pem')
        rescue Mysql2::Error
          # the bogus paths never reach a real handshake; the warning precedes it.
        end
      end.to output(/:sslkey and :tls_key were both given with different values; :tls_key wins/).to_stderr
    end

    it "does not warn when a legacy :ssl* option and its :tls_* alias are given the same value" do
      expect do
        begin
          new_client(sslkey: '/path/to/key.pem', tls_key: '/path/to/key.pem', tls_cert: '/path/to/client-cert.pem')
        rescue Mysql2::Error
          # the bogus path never reaches a real handshake; the warning precedes it.
        end
      end.not_to output(/were both given with different values/).to_stderr
    end

    it "warns when :ssl_mode and its :tls_mode alias are given with different values" do
      expect do
        new_client(ssl_mode: :required, tls_mode: :disabled)
      end.to output(/:ssl_mode and :tls_mode were both given with different values; :tls_mode wins/).to_stderr
    end
  end

  context "TLS option validation" do
    # These raises all fire in Client#initialize before any connection is
    # attempted, so they hold on every build and don't need a TLS-enabled
    # server. The zero-value skips cover ancient no-ssl_mode builds where
    # every SSL_MODE_* constant collapses to 0.

    it "refuses combining fingerprint pinning with a verifying ssl_mode" do
      skip "this build has no verifying ssl_mode" if Mysql2::Client::SSL_MODE_VERIFY_IDENTITY.zero?

      # The connector runs the FINGERPRINT check instead of the HOST/TRUST
      # checks when a fingerprint is pinned: one of the two requested
      # verification models would silently not run.
      expect do
        new_client(tls_peer_fingerprint: 'ab' * 32, ssl_mode: :verify_identity)
      end.to raise_error(Mysql2::Error::ConnectionError, /mutually exclusive/)
    end

    it "refuses fingerprint pinning on client libraries that cannot enforce it" do
      skip "this build supports fingerprint pinning" if Mysql2::Client::TLS_PEER_FINGERPRINT_SUPPORTED

      expect do
        new_client(tls_peer_fingerprint: 'ab' * 32)
      end.to raise_error(Mysql2::Error::ConnectionError, /tls_peer_fingerprint/)
    end

    it "refuses :tls_passphrase on client libraries that have no way to decrypt an encrypted key" do
      skip "this build supports :tls_passphrase" if Mysql2::Client::TLS_PASSPHRASE_SUPPORTED

      expect do
        new_client(tls_passphrase: 'secret')
      end.to raise_error(Mysql2::Error::ConnectionError, /tls_passphrase/)
    end

    it "refuses verify_identity outright when this build cannot enforce hostname verification" do
      # Mirrors rb_set_ssl_mode_option's open-ended MariaDB-family
      # predicate: everything 3.0+ except the MySQL native-verify tiers.
      version = Mysql2::Client.info[:id]
      mysql_native_verify = (50703...50711).cover?(version) || (60103...60200).cover?(version)
      mariadb = version >= 30000 && !mysql_native_verify
      skip "this build enforces verify_identity" unless mariadb && Mysql2::Client::TLS_PEER_IDENTITY_VERIFICATION.nil?

      # Connecting with the hostname check silently skipped is exactly the
      # #879 failure mode; an unenforceable build must raise, not degrade.
      expect do
        new_client(ssl_mode: :verify_identity, sslca: '/nonexistent/ca.pem')
      end.to raise_error(Mysql2::Error::ConnectionError, /cannot be enforced/)
    end

    it "refuses sslverify: false combined with a verifying ssl_mode" do
      skip "this build has no verifying ssl_mode" if Mysql2::Client::SSL_MODE_VERIFY_IDENTITY.zero?

      # sslverify: false says the connection doesn't need to be verified;
      # ssl_mode: :verify_identity/:verify_ca says mysql2 must refuse it
      # unless it is. Pick one instead of silently choosing between them.
      expect do
        new_client(sslverify: false, ssl_mode: :verify_identity)
      end.to raise_error(Mysql2::Error::ConnectionError, /sslverify: false conflicts/)

      expect do
        new_client(sslverify: false, ssl_mode: :verify_ca)
      end.to raise_error(Mysql2::Error::ConnectionError, /sslverify: false conflicts/)
    end

    it "does not refuse sslverify: false combined with a non-verifying ssl_mode" do
      expect { Klient.new(sslverify: false, ssl_mode: :required) }.not_to raise_error
      expect { Klient.new(sslverify: false) }.not_to raise_error
    end

    it "maps sslverify: true onto ssl_mode: :verify_identity when no ssl_mode is given" do
      skip "this build has no verifying ssl_mode" if Mysql2::Client::SSL_MODE_VERIFY_IDENTITY.zero?

      # Mirrors the "refuses verify_identity outright" predicate above: a
      # MariaDB-family build without the enforcement callback refuses the
      # mapped :verify_identity at Client.new rather than silently skipping
      # the hostname check. That refusal is itself proof the mapping
      # happened -- :sslverify alone never trips verify_identity
      # enforcement (see "does not refuse sslverify: false" above).
      version = Mysql2::Client.info[:id]
      mysql_native_verify = (50703...50711).cover?(version) || (60103...60200).cover?(version)
      mariadb = version >= 30000 && !mysql_native_verify

      if mariadb && Mysql2::Client::TLS_PEER_IDENTITY_VERIFICATION.nil?
        expect { Klient.new(sslverify: true) }.to raise_error(Mysql2::Error::ConnectionError, /cannot be enforced/)
      else
        client = Klient.new(sslverify: true)
        expect(client.connect_args.last[6] & Mysql2::Client::SSL_VERIFY_SERVER_CERT).not_to eql(0)
      end
    end

    it "lets an explicit ssl_mode win over sslverify: true" do
      expect { Klient.new(sslverify: true, ssl_mode: :required) }.not_to raise_error
    end
  end

  def run_gc
    if defined?(Rubinius)
      GC.run(true)
    else
      GC.start
    end
    sleep(0.5)
  end

  it "should terminate connections when calling close" do
    # rubocop:disable Lint/AmbiguousBlockAssociation
    expect do
      client = Mysql2::Client.new(DatabaseCredentials['root'])
      connection_id = client.thread_id
      client.close

      # mysql_close sends a quit command without waiting for a response
      # so give the server some time to handle the detect the closed connection
      closed = false
      10.times do
        closed = @client.query("SHOW PROCESSLIST").none? { |row| row['Id'] == connection_id }
        break if closed

        sleep(0.1)
      end
      expect(closed).to eq(true)
    end.to_not change {
      @client.query("SHOW STATUS LIKE 'Aborted_%'").to_a
    }
    # rubocop:enable Lint/AmbiguousBlockAssociation
  end

  it "should reap (not just drop) a pending abandoned streaming result when the client is closed" do
    # Unlike a pending statement close, mysql_close() has no side effect that
    # reclaims a MYSQL_RES's client-side row buffers -- see
    # mysql2_reap_pending_result_frees vs mysql2_drop_pending_stmt_closes in
    # ext/mysql2/client.c. #close must actually free a queued result, not
    # just clear the bookkeeping, or that memory leaks for the rest of the
    # process. This can't observe the leak directly from Ruby, but it does
    # confirm #close runs the real (potentially blocking) free without
    # erroring or hanging, with enough unread rows on the wire to matter.
    client = new_client
    sql = 'WITH RECURSIVE seq AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM seq WHERE n < 500) SELECT n FROM seq'
    begin
      GC.stress = true
      result = client.query(sql, stream: true, cache_rows: false)
      result.first
      result = nil # rubocop:disable Lint/UselessAssignment
    ensure
      GC.stress = false
    end
    GC.start

    expect { client.close }.to_not raise_error
    expect(client.pending_result_frees).to eq(0)
  end

  it "should not leave dangling connections after garbage collection" do
    run_gc

    # Track these 10 connections by thread_id rather than by a status
    # counter like Threads_connected or Aborted_clients: those are scoped to
    # the whole server.
    thread_ids = 10.times.map do
      Mysql2::Client.new(DatabaseCredentials['root']).tap { |c| c.query('SELECT 1') }.thread_id
    end

    run_gc

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      still_connected = @client.query("SHOW PROCESSLIST").map { |row| row['Id'] }
      break if (thread_ids & still_connected).empty?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end

    still_connected = @client.query("SHOW PROCESSLIST").map { |row| row['Id'] }
    expect(thread_ids & still_connected).to eq([])
  end

  context "#set_server_option" do
    let(:client) do
      new_client.tap do |client|
        client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_ON)
      end
    end

    it 'returns true when multi_statements is enable' do
      expect(client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_ON)).to be true
    end

    it 'returns true when multi_statements is disable' do
      expect(client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_OFF)).to be true
    end

    it 'returns false when multi_statements is neither OPTION_MULTI_STATEMENTS_OFF or OPTION_MULTI_STATEMENTS_ON' do
      expect(client.set_server_option(344)).to be false
    end

    it 'enables multiple-statement' do
      client.query("SELECT 1;SELECT 2;")

      expect(client.next_result).to be true
      expect(client.store_result.first).to eql('2' => 2)
      expect(client.next_result).to be false
    end

    it 'disables multiple-statement' do
      client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_OFF)

      expect { client.query("SELECT 1;SELECT 2;") }.to raise_error(Mysql2::Error)
    end
  end

  context "#automatic_close" do
    it "is enabled by default" do
      expect(new_client.automatic_close?).to be(true)
    end

    if RUBY_PLATFORM =~ /mingw|mswin/
      it "cannot be disabled" do
        expect do
          client = new_client(automatic_close: false)
          expect(client.automatic_close?).to be(true)
        end.to output(/always closed by garbage collector/).to_stderr

        expect do
          client = new_client(automatic_close: true)
          expect(client.automatic_close?).to be(true)
        end.to_not output(/always closed by garbage collector/).to_stderr

        expect do
          client = new_client(automatic_close: true)
          client.automatic_close = false
          expect(client.automatic_close?).to be(true)
        end.to output(/always closed by garbage collector/).to_stderr
      end
    else
      it "can be configured" do
        client = new_client(automatic_close: false)
        expect(client.automatic_close?).to be(false)
      end

      it "can be assigned" do
        client = new_client
        client.automatic_close = false
        expect(client.automatic_close?).to be(false)

        client.automatic_close = true
        expect(client.automatic_close?).to be(true)

        client.automatic_close = nil
        expect(client.automatic_close?).to be(false)

        client.automatic_close = 9
        expect(client.automatic_close?).to be(true)
      end

      it "should not close connections when running in a child process" do
        run_gc
        # The fd-invalidation trick that makes this safe (see invalidate_fd()
        # in ext/mysql2/client.c) only patches up the raw socket fd. A TLS
        # connection also has an OpenSSL session/record-layer state machine
        # that fork() duplicates right along with the fd; the child's real
        # round-trip in this test advances that state independently of the
        # parent's copy, permanently desyncing the parent's side regardless
        # of anything invalidate_fd() does afterward. So this test is only
        # meaningful over a plaintext connection.
        client = Mysql2::Client.new(DatabaseCredentials['root'].merge('ssl_mode' => 'disabled'))
        client.automatic_close = false

        child = fork do
          client.query('SELECT 1')
          client = nil
          run_gc
        end

        Process.wait(child)

        # this will throw an error if the underlying socket was shutdown by the
        # child's GC
        expect { client.query('SELECT 1') }.to_not raise_exception
        client.close
      end

      it "should not close the parent's connection when a stale reference is GC'd in a child, even with automatic_close left at its default" do
        run_gc
        client = Mysql2::Client.new(DatabaseCredentials['root'].merge('ssl_mode' => 'disabled'))
        expect(client.automatic_close?).to be(true)

        child = fork do
          # Inherit the connection without reconnecting, then abandon it --
          # the common real-world mistake this is meant to protect against.
          client = nil
          run_gc
        end

        Process.wait(child)

        # this will throw an error if the underlying socket was shutdown by
        # the child's GC, per the pid mismatch it should have detected
        expect { client.query('SELECT 1') }.to_not raise_exception
        client.close
      end
    end
  end

  context "fork safety" do
    it "warns, but does not raise, when a query, ping, or prepare is issued from a forked child that hasn't reconnected" do
      skip "fork() is not implemented on Windows" if RUBY_PLATFORM =~ /mingw|mswin/

      client = new_client(ssl_mode: 'disabled')
      read, write = IO.pipe

      child = fork do
        read.close
        write.puts client.query('SELECT 1').first['1']
        write.puts client.ping
        write.puts client.prepare('SELECT 1').execute.first['1']
        write.close
      end
      write.close

      Process.wait(child)
      expect(read.gets).to eq("1\n")
      expect(read.gets).to eq("true\n")
      expect(read.gets).to eq("1\n")
      read.close
      client.close
    end
  end

  it "should be able to connect to database with numeric-only name" do
    database = 1235
    @client.query "CREATE DATABASE IF NOT EXISTS `#{database}`"

    expect do
      new_client('database' => database)
    end.not_to raise_error

    @client.query "DROP DATABASE IF EXISTS `#{database}`"
  end

  it "should respond to #close" do
    expect(@client).to respond_to(:close)
  end

  it "should be able to close properly" do
    expect(@client.close).to be_nil
    expect do
      @client.query "SELECT 1"
    end.to raise_error(Mysql2::Error)
  end

  context "#closed?" do
    it "should return false when connected" do
      expect(@client.closed?).to eql(false)
    end

    it "should return true after close" do
      @client.close
      expect(@client.closed?).to eql(true)
    end
  end

  context "#discard!" do
    it "marks the client closed and further commands raise" do
      client = new_client
      expect(client.discard!).to be_nil
      expect(client.closed?).to eql(true)
      expect do
        client.query "SELECT 1"
      end.to raise_error(Mysql2::Error, /not connected/)
    end

    # Client#socket raises on Windows, so fd release isn't observable there
    unless RUBY_PLATFORM =~ /mingw|mswin/
      it "releases this process's socket fd" do
        client = new_client
        fd = client.socket
        client.discard!
        expect do
          IO.for_fd(fd, autoclose: false).stat
        end.to raise_error(Errno::EBADF)
      end
    end

    it "is idempotent, in either order with close" do
      client = new_client
      client.discard!
      expect(client.discard!).to be_nil
      expect(client.close).to be_nil

      client = new_client
      client.close
      expect(client.discard!).to be_nil
    end

    it "does not resurrect the connection via reconnect" do
      client = new_client(reconnect: true)
      client.discard!
      expect(client.closed?).to eql(true)
      expect do
        client.query "SELECT 1"
      end.to raise_error(Mysql2::Error, /not connected/)
    end

    it "can discard mid-stream" do
      client = new_client
      result = client.query("SELECT 1 AS a UNION SELECT 2", stream: true, cache_rows: false)
      result.first
      client.discard!
      expect(client.closed?).to eql(true)
    end

    unless RUBY_PLATFORM =~ /mingw|mswin/
      it "leaves the parent's session intact when a forked child discards" do
        client = Mysql2::Client.new(DatabaseCredentials['root'])
        thread_id = client.thread_id

        child = fork do
          client.discard!
          status = client.closed? ? 0 : 1
          client = nil
          run_gc
          exit! status
        end

        _, status = Process.waitpid2(child)
        expect(status.exitstatus).to eq(0)

        # both would raise if the child's discard!, or the GC run after it,
        # had sent a QUIT or shutdown() down the shared socket
        expect(client.query('SELECT 1 AS one').first).to eq('one' => 1)
        expect(client.thread_id).to eq(thread_id)
        client.close
      end

      it "leaves the parent's prepared statements intact when a forked child discards" do
        client = new_client
        stmt = client.prepare('SELECT ? AS n')

        child = fork do
          client.discard!
          exit!
        end
        Process.wait(child)

        expect(stmt.execute(42).first).to eq('n' => 42)
        stmt.close
      end

      it "leaves the child's session intact when the parent discards" do
        signal_r, signal_w = IO.pipe
        result_r, result_w = IO.pipe

        client = new_client
        child = fork do
          signal_w.close
          result_r.close
          signal_r.read(1) # wait for the parent's discard!
          row = client.query("SELECT 'child session intact' AS proof").first
          result_w.write(row.fetch('proof'))
          exit!
        end

        signal_r.close
        result_w.close
        client.discard!
        signal_w.write('!')
        expect(result_r.read).to eq('child session intact')
        Process.wait(child)
      end
    end
  end

  it "should not try to query closed mysql connection" do
    client = new_client(reconnect: true)
    expect(client.close).to be_nil
    expect do
      client.query "SELECT 1"
    end.to raise_error(Mysql2::Error)
  end

  it "should respond to #query" do
    expect(@client).to respond_to(:query)
  end

  it "should respond to #warning_count" do
    expect(@client).to respond_to(:warning_count)
  end

  context "#warning_count" do
    context "when no warnings" do
      it "should 0" do
        @client.query('select 1')
        expect(@client.warning_count).to eq(0)
      end
    end
    context "when has a warnings" do
      it "should > 0" do
        # "the statement produces extra information that can be viewed by issuing a SHOW WARNINGS"
        # https://dev.mysql.com/doc/refman/5.7/en/show-warnings.html
        @client.query('DROP TABLE IF EXISTS test.no_such_table')
        expect(@client.warning_count).to be > 0
      end
    end
  end

  it "should respond to #query_info" do
    expect(@client).to respond_to(:query_info)
  end

  context "#query_info" do
    context "when no info present" do
      it "should 0" do
        @client.query('select 1')
        expect(@client.query_info).to be_empty
        expect(@client.query_info_string).to be_nil
      end
    end
    context "when has some info" do
      it "should retrieve it" do
        @client.query "USE test"
        @client.query "CREATE TABLE IF NOT EXISTS infoTest (`id` int(11) NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"

        # http://dev.mysql.com/doc/refman/5.0/en/mysql-info.html says
        # # Note that mysql_info() returns a non-NULL value for INSERT ... VALUES only for the multiple-row form of the statement (that is, only if multiple value lists are specified).
        @client.query("INSERT INTO infoTest (blah) VALUES (1234),(4535)")

        expect(@client.query_info).to eql(records: 2, duplicates: 0, warnings: 0)
        expect(@client.query_info_string).to eq('Records: 2  Duplicates: 0  Warnings: 0')

        @client.query "DROP TABLE infoTest"
      end
    end
  end

  context ":local_infile" do
    before(:context) do
      new_client(local_infile: true) do |client|
        local = client.query "SHOW VARIABLES LIKE 'local_infile'"
        local_enabled = local.any? { |x| x['Value'] == 'ON' }
        skip("DON'T WORRY, THIS TEST PASSES - but LOCAL INFILE is not enabled in your MySQL daemon.") unless local_enabled

        client.query %[
          CREATE TABLE IF NOT EXISTS infileTest (
            id MEDIUMINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
            foo VARCHAR(10),
            bar MEDIUMTEXT
          )
        ]
      end
    end

    after(:context) do
      new_client do |client|
        client.query "DROP TABLE IF EXISTS infileTest"
      end
    end

    it "should raise an error when local_infile is disabled" do
      client = new_client(local_infile: false)
      expect do
        client.query "LOAD DATA LOCAL INFILE 'spec/test_data' INTO TABLE infileTest"
      end.to raise_error(Mysql2::Error, /command is not allowed/)
    end

    it "should raise an error when a non-existent file is loaded" do
      client = new_client(local_infile: true)
      expect do
        client.query "LOAD DATA LOCAL INFILE 'this/file/is/not/here' INTO TABLE infileTest"
      end.to raise_error(Mysql2::Error, 'No such file or directory: this/file/is/not/here')
    end

    it "should LOAD DATA LOCAL INFILE" do
      client = new_client(local_infile: true)
      client.query "LOAD DATA LOCAL INFILE 'spec/test_data' INTO TABLE infileTest"
      info = client.query_info
      expect(info).to eql(records: 1, deleted: 0, skipped: 0, warnings: 0)

      result = client.query "SELECT * FROM infileTest"
      expect(result.first).to eql('id' => 1, 'foo' => 'Hello', 'bar' => 'World')
    end
  end

  it "should expect connect_timeout to be a positive integer" do
    expect do
      new_client(connect_timeout: -1)
    end.to raise_error(Mysql2::Error)
  end

  it "should expect read_timeout to be a positive integer" do
    expect do
      new_client(read_timeout: -1)
    end.to raise_error(Mysql2::Error)
  end

  it "should expect write_timeout to be a positive integer" do
    expect do
      new_client(write_timeout: -1)
    end.to raise_error(Mysql2::Error)
  end

  it "should allow nil read_timeout" do
    client = new_client(read_timeout: nil)

    expect(client.read_timeout).to be_nil
  end

  context "read_timeout=/write_timeout= on a live connection" do
    it "changes read_timeout enforcement mid-session" do
      # do_query's ivar-based wait loop (client.c) is #ifndef _WIN32 only;
      # on Windows read_timeout is enforced purely by whatever
      # mysql_options() applied at connect, same as write_timeout, and a
      # live change raises instead -- see the Windows-only spec below.
      skip "not implemented on Windows -- see set_read_timeout in client.c" if RUBY_PLATFORM =~ /mingw|mswin/

      client = new_client(read_timeout: 10)
      client.read_timeout = 1

      start = clock_time
      expect { client.query("SELECT SLEEP(3)") }.to raise_error(Mysql2::Error::TimeoutError)
      expect(clock_time - start).to be < 2
    end

    it "raises when read_timeout is changed on an already-connected client on Windows" do
      skip "read_timeout=/query(read_timeout:) work live on non-Windows -- see the spec above" unless RUBY_PLATFORM =~ /mingw|mswin/

      client = new_client(read_timeout: 10)
      expect { client.read_timeout = 1 }.to raise_error(Mysql2::Error, /already-connected/)
      expect(client.query("SELECT 1 AS one").first).to eql('one' => 1)
    end

    it "raises when write_timeout is changed on an already-connected client" do
      # Unlike read_timeout, mysql2 has no enforcement mechanism of its own
      # for writes; the underlying libraries only apply
      # MYSQL_OPT_WRITE_TIMEOUT once, during the initial connect (both
      # libmysqlclient and MariaDB Connector/C -- mysql_options() is
      # documented as pre-connect-only, and neither implementation reapplies
      # it to a live session). Raise rather than silently accept a value
      # that would never take effect.
      client = new_client
      expect { client.write_timeout = 5 }.to raise_error(Mysql2::Error, /already-connected/)
      expect(client.query("SELECT 1 AS one").first).to eql('one' => 1)
    end

    it "exposes write_timeout set at connect time" do
      client = new_client(write_timeout: 7)
      expect(client.write_timeout).to eql(7)
    end
  end

  context "#query per-query :read_timeout / :write_timeout" do
    it "overrides read_timeout for a single query without changing the connection default" do
      skip "not implemented on Windows -- see set_read_timeout in client.c" if RUBY_PLATFORM =~ /mingw|mswin/

      client = new_client(read_timeout: 10)

      start = clock_time
      expect { client.query("SELECT SLEEP(3)", read_timeout: 1) }.to raise_error(Mysql2::Error::TimeoutError)
      expect(clock_time - start).to be < 2
    end

    it "restores the connection's read_timeout after a per-query override, even without a timeout firing" do
      skip "not implemented on Windows -- see set_read_timeout in client.c" if RUBY_PLATFORM =~ /mingw|mswin/

      client = new_client(read_timeout: 10)

      client.query("SELECT SLEEP(1)", read_timeout: 5)
      expect(client.read_timeout).to eql(10)
    end

    it "raises a per-query :read_timeout on Windows instead of silently not applying it" do
      skip "read_timeout: works live on non-Windows -- see the specs above" unless RUBY_PLATFORM =~ /mingw|mswin/

      client = new_client(read_timeout: 10)
      expect { client.query("SELECT 1", read_timeout: 5) }.to raise_error(Mysql2::Error, /already-connected/)
      expect(client.read_timeout).to eql(10)
      expect(client.query("SELECT 1 AS one").first).to eql('one' => 1)
    end

    it "restores the connection's read_timeout after a per-query override raises for another reason" do
      client = new_client(read_timeout: 10)

      expect { client.query("SELECT 1", read_timeout: -1) }.to raise_error(Mysql2::Error, /positive integer/)
      expect(client.read_timeout).to eql(10)
      expect(client.query("SELECT 1 AS one").first).to eql('one' => 1)
    end

    it "rejects a per-query :write_timeout instead of silently ignoring it" do
      client = new_client
      expect { client.query("SELECT 1", write_timeout: 5) }.to raise_error(ArgumentError, /write_timeout/)
      expect(client.query("SELECT 1 AS one").first).to eql('one' => 1)
    end

    it "still raises TypeError for an explicit nil options argument" do
      client = new_client
      expect { client.query("SELECT 1", nil) }.to raise_error(TypeError)
    end
  end

  it "should set default program_name in connect_attrs" do
    skip("DON'T WORRY, THIS TEST PASSES - but PERFORMANCE SCHEMA is not enabled in your MySQL daemon.") unless performance_schema_enabled
    client = new_client
    if Mysql2::Client::CONNECT_ATTRS.zero? || client.server_info[:version].match(/10.[01].\d+-MariaDB/)
      pending('Both client and server versions must be MySQL 5.6 or MariaDB 10.2 or later.')
    end
    result = client.query("SELECT attr_value FROM performance_schema.session_account_connect_attrs WHERE processlist_id = connection_id() AND attr_name = 'program_name'")
    expect(result.first['attr_value']).to eq($PROGRAM_NAME)
  end

  it "should set custom connect_attrs" do
    skip("DON'T WORRY, THIS TEST PASSES - but PERFORMANCE SCHEMA is not enabled in your MySQL daemon.") unless performance_schema_enabled
    client = new_client(connect_attrs: { program_name: 'my_program_name', foo: 'fooval', bar: 'barval' })
    if Mysql2::Client::CONNECT_ATTRS.zero? || client.server_info[:version].match(/10.[01].\d+-MariaDB/)
      pending('Both client and server versions must be MySQL 5.6 or MariaDB 10.2 or later.')
    end
    results = Hash[client.query("SELECT * FROM performance_schema.session_account_connect_attrs WHERE processlist_id = connection_id()").map { |x| x.values_at('ATTR_NAME', 'ATTR_VALUE') }]
    expect(results['program_name']).to eq('my_program_name')
    expect(results['foo']).to eq('fooval')
    expect(results['bar']).to eq('barval')
  end

  context "#query" do
    it "should reject stream: {size: N}, which only prepared statements support" do
      # Text-protocol streaming is mysql_use_result -- no cursor, no
      # prefetch to size. Raising beats silently streaming row-by-row.
      expect do
        @client.query("SELECT 1", stream: { size: 10 })
      end.to raise_error(ArgumentError, /prepared statements/)
    end

    it "should let you query again if iterating is finished when streaming" do
      @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false).each.to_a

      expect do
        @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false)
      end.to_not raise_error
    end

    it "should let you query again if the previous streaming result was abandoned (not fully iterated)" do
      # Only fetch the first row and never touch the rest of the cursor.
      # The next query must not raise "Commands out of sync" -- the client
      # should force-drain the abandoned cursor itself, even though GC
      # hasn't had a chance to collect the old Result yet.
      @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false).first

      expect do
        @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false)
      end.to_not raise_error
    end

    it "should let you query again after breaking out of #each on a streaming result early" do
      # rubocop:disable Lint/UnreachableLoop
      @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3", stream: true, cache_rows: false).each do |_row|
        break
      end
      # rubocop:enable Lint/UnreachableLoop

      result = @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3", stream: true, cache_rows: false)
      expect(result.to_a).to eq([{ '1' => 1 }, { '1' => 2 }, { '1' => 3 }])
    end

    it "should let you query again after an exception raised inside a streaming #each block" do
      # rubocop:disable Lint/UnreachableLoop
      expect do
        @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3", stream: true, cache_rows: false).each do |_row|
          raise "boom"
        end
      end.to raise_error("boom")
      # rubocop:enable Lint/UnreachableLoop

      result = @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3", stream: true, cache_rows: false)
      expect(result.to_a).to eq([{ '1' => 1 }, { '1' => 2 }, { '1' => 3 }])
    end

    it "should let you query again if a streaming result was abandoned and only collected by the GC" do
      @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3", stream: true, cache_rows: false).first
      run_gc

      result = @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3", stream: true, cache_rows: false)
      expect(result.to_a).to eq([{ '1' => 1 }, { '1' => 2 }, { '1' => 3 }])
    end

    it "should only accept strings as the query parameter" do
      expect do
        @client.query ["SELECT 'not right'"]
      end.to raise_error(TypeError)
    end

    it "should not retain query options set on a query for subsequent queries, but should retain it in the result" do
      result = @client.query "SELECT 1", something: :else
      expect(@client.query_options[:something]).to be_nil
      expect(result.instance_variable_get('@query_options')).to eql(@client.query_options.merge(something: :else))
      expect(@client.instance_variable_get('@current_query_options')).to eql(@client.query_options.merge(something: :else))

      result = @client.query "SELECT 1"
      expect(result.instance_variable_get('@query_options')).to eql(@client.query_options)
      expect(@client.instance_variable_get('@current_query_options')).to eql(@client.query_options)
    end

    it "should allow changing query options for subsequent queries" do
      @client.query_options[:something] = :else
      result = @client.query "SELECT 1"
      expect(@client.query_options[:something]).to eql(:else)
      expect(result.instance_variable_get('@query_options')[:something]).to eql(:else)

      # Clean up after this test
      @client.query_options.delete(:something)
      expect(@client.query_options[:something]).to be_nil
    end

    it "should raise TypeError when options are explicitly nil or false" do
      expect { @client.query "SELECT 1", nil }.to raise_error(TypeError, 'no implicit conversion of nil into Hash')
      expect { @client.query "SELECT 1", false }.to raise_error(TypeError, 'no implicit conversion of false into Hash')
    end

    it "should return results as a hash by default" do
      expect(@client.query("SELECT 1").first).to be_an_instance_of(Hash)
    end

    it "should be able to return results as an array" do
      expect(@client.query("SELECT 1", as: :array).first).to be_an_instance_of(Array)
      @client.query("SELECT 1").each(as: :array)
    end

    it "should be able to return results with symbolized keys" do
      expect(@client.query("SELECT 1", symbolize_keys: true).first.keys[0]).to be_an_instance_of(Symbol)
    end

    it "should require an open connection" do
      @client.close
      expect do
        @client.query "SELECT 1"
      end.to raise_error(Mysql2::Error)
    end

    it "should detect closed connection on query read error" do
      connection_id = @client.thread_id
      new_thread do
        sleep(0.1)
        Mysql2::Client.new(DatabaseCredentials['root']).tap do |supervisor|
          supervisor.query("KILL #{connection_id}")
        end.close
      end
      expect do
        @client.query("SELECT SLEEP(1)")
      end.to raise_error(Mysql2::Error) { |e|
        # Over TLS, OpenSSL intercepts the abrupt close as a record-layer
        # EOF before the MySQL protocol layer gets a chance to generate its
        # own "Lost connection" message -- both are the same underlying
        # event (the server killed the connection).
        expect(e.message).to match(%r{Lost connection|TLS/SSL error})
      }

      if RUBY_PLATFORM !~ /mingw|mswin/
        expect do
          @client.socket
        end.to raise_error(Mysql2::Error, 'MySQL client is not connected')
      end
    end

    if RUBY_PLATFORM !~ /mingw|mswin/
      it "should not allow another query to be sent without fetching a result first" do
        @client.query("SELECT 1", async: true)
        expect do
          @client.query("SELECT 1")
        end.to raise_error(Mysql2::Error)
      end

      it "should not let query_options mutations affect an already-issued async query" do
        @client.query_options[:async] = true
        @client.query("SELECT 1 AS one")

        # Neither mutation may leak into the issued query's snapshot:
        # :stream would switch async_result to streaming delivery, and
        # :symbolize_keys would change how its rows are built.
        @client.query_options[:stream] = true
        @client.query_options[:symbolize_keys] = true

        expect(@client.async_result.first).to eql('one' => 1)
      end

      it "should prevent using a connection held by a dead thread, but not closing it" do
        thr = new_thread do
          @client.query("SELECT SLEEP(2)")
        end
        thr.join(0.5)
        thr.kill
        thr.join

        expect { @client.query("SELECT 4") }.to raise_error(Mysql2::Error)
        @client.close
      end

      it "should describe the thread holding the active query" do
        out_queue = Queue.new
        in_queue = Queue.new

        thr = new_thread do
          @client.query("SELECT 1", async: true)
          out_queue << Fiber.current
          in_queue.pop
        end

        fiber = out_queue.pop
        expect { @client.query('SELECT 1') }.to raise_error(Mysql2::Error, Regexp.new(Regexp.escape(fiber.inspect)))
        in_queue.close
        thr.join
      end

      it "should timeout if we wait longer than :read_timeout" do
        client = new_client(read_timeout: 0)
        expect do
          client.query('SELECT SLEEP(0.1)')
        end.to raise_error(Mysql2::Error::TimeoutError)
      end

      # XXX this test is not deterministic (because Unix signal handling is not)
      # and may fail on a loaded system
      it "should run signal handlers while waiting for a response" do
        kill_time = 0.25
        query_time = 4 * kill_time

        mark = {}

        begin
          trap(:USR1) { mark.store(:USR1, clock_time) }
          pid = fork do
            sleep kill_time # wait for client query to start
            Process.kill(:USR1, Process.ppid)
            sleep # wait for explicit kill to prevent GC disconnect
          end
          mark.store(:QUERY_START, clock_time)
          @client.query("SELECT SLEEP(#{query_time})")
          mark.store(:QUERY_END, clock_time)
        ensure
          Process.kill(:TERM, pid)
          Process.waitpid2(pid)
          trap(:USR1, 'DEFAULT')
        end

        # the query ran uninterrupted
        expect(mark.fetch(:QUERY_END) - mark.fetch(:QUERY_START)).to be_within(0.2).of(query_time)
        # signals fired while the query was running
        expect(mark.fetch(:USR1)).to be_between(mark.fetch(:QUERY_START), mark.fetch(:QUERY_END))
      end

      it "#socket should return a Fixnum (file descriptor from C)" do
        expect(@client.socket).to be_an_instance_of(0.class)
        expect(@client.socket).not_to eql(0)
      end

      it "#socket should require an open connection" do
        @client.close
        expect do
          @client.socket
        end.to raise_error(Mysql2::Error)
      end

      it 'should be impervious to connection-corrupting timeouts in #execute' do
        client = new_client(ssl_mode: 'disabled')

        # attempt to break the connection
        stmt = client.prepare('SELECT SLEEP(?)')
        expect { Timeout.timeout(0.1) { stmt.execute(1) } }.to raise_error(Timeout::Error)
        stmt.close

        # expect the connection to not be broken
        expect { client.query('SELECT 1') }.to_not raise_error
      end

      it 'connection-corrupting timeouts in #execute over TLS may or may not break the connection' do
        client = new_client(ssl_mode: 'required')

        # attempt to break the connection
        stmt = client.prepare('SELECT SLEEP(?)')
        expect { Timeout.timeout(0.1) { stmt.execute(1) } }.to raise_error(Timeout::Error)
        stmt.close

        # Whether interrupting a query mid-read leaves the TLS session itself
        # resumable appears to depend on the platform/OpenSSL build (observed:
        # recovers fine on macOS's stack, doesn't on Linux's, even though both
        # are equally using TLS) -- accept either outcome here rather than
        # assert a specific one.
        begin
          client.query('SELECT 1')
        rescue Mysql2::Error
          # also acceptable over TLS -- see above
        end
      end

      context 'when a non-standard exception class is raised' do
        # Every test in this context pins ssl_mode: disabled deliberately.
        # Timeout.timeout interrupts a blocking query by raising inside the
        # thread, which only works if the underlying blocking read is
        # actually interruptible -- on some OpenSSL builds, an interrupted
        # SSL_read is retried internally rather than returning, which
        # defeats the interrupt entirely and hangs the thread forever
        # instead of raising. See the TLS-specific test below.
        it "should close the connection when an exception is raised" do
          client = new_client(ssl_mode: 'disabled')
          expect { Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { client.query('SELECT 1') }.to raise_error(Mysql2::Error, 'MySQL client is not connected')
        end

        it "should handle Timeouts without leaving the connection hanging if reconnect is true" do
          if RUBY_PLATFORM.include?('darwin') && @client.server_info.fetch(:version).start_with?('5.5')
            pending('MySQL 5.5 on OSX is afflicted by an unknown bug that breaks this test. See #633 and #634.')
          end

          client = new_client(ssl_mode: 'disabled', reconnect: true)

          expect { Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { client.query('SELECT 1') }.to_not raise_error
        end

        it "should handle Timeouts without leaving the connection hanging if reconnect is set to true after construction" do
          if RUBY_PLATFORM.include?('darwin') && @client.server_info.fetch(:version).start_with?('5.5')
            pending('MySQL 5.5 on OSX is afflicted by an unknown bug that breaks this test. See #633 and #634.')
          end

          client = new_client(ssl_mode: 'disabled')

          expect { Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { client.query('SELECT 1') }.to raise_error(Mysql2::Error)

          client.reconnect = true

          expect { Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') } }.to raise_error(ArgumentError)
          expect { client.query('SELECT 1') }.to_not raise_error
        end

        it "interrupting a query over TLS may raise or hang, depending on the platform/OpenSSL build" do
          client = new_client(ssl_mode: 'required')

          # A plain Timeout.timeout around the query isn't safe to use here:
          # if the interrupt is defeated (see comment above), it would just
          # hang this example forever right along with the query. Run the
          # attempt on its own thread instead and give up waiting on it
          # after a generous bound -- the thread is abandoned rather than
          # joined if that happens, which is fine, since the process exiting
          # at the end of the suite reclaims it either way.
          th = Thread.new do
            begin
              Timeout.timeout(0.1, ArgumentError) { client.query('SELECT SLEEP(1)') }
            rescue StandardError => e
              e
            end
          end

          if th.join(5)
            expect(th.value).to be_a(ArgumentError)
            begin
              client.query('SELECT 1')
            rescue Mysql2::Error
              # also acceptable over TLS -- see comment above
            end
          else
            skip 'Timeout-interrupting a query over TLS hung instead of raising on this platform/OpenSSL build'
          end
        end
      end

      it "threaded queries should be supported" do
        sleep_time = 0.5

        # Note that each thread opens its own database connection
        start = clock_time
        threads = Array.new(5) do
          new_thread do
            new_client do |client|
              client.query("SELECT SLEEP(#{sleep_time})")
            end
            Thread.current.object_id
          end
        end
        values = threads.map(&:value)
        stop = clock_time

        # This check demonstrates that the threads are sleeping concurrently:
        # In the serial case, the difference would be a multiple of sleep time
        expect(stop - start).to be_within(0.2).of(sleep_time)

        expect(values).to match_array(threads.map(&:object_id))
      end

      it "evented async queries should be supported" do
        # should immediately return nil
        expect(@client.query("SELECT sleep(0.5)", async: true)).to eql(nil)

        io_wrapper = IO.for_fd(@client.socket, autoclose: false)
        loops = 0
        loops += 1 until IO.select([io_wrapper], nil, nil, 0.01)

        # make sure we waited some period of time
        expect(loops >= 1).to be true

        result = @client.async_result
        expect(result).to be_an_instance_of(Mysql2::Result)
      end

      it "can close a connection with on the fly async query" do
        expect(@client.query("SELECT sleep(0.5)", async: true)).to eql(nil)
        @client.close
        expect(@client.async_result).to be nil
      end
    end

    context "Multiple results sets" do
      before(:example) do
        @multi_client = new_client(flags: Mysql2::Client::MULTI_STATEMENTS)
      end

      it "should raise an exception when one of multiple statements fails" do
        result = @multi_client.query("SELECT 1 AS 'set_1'; SELECT * FROM invalid_table_name; SELECT 2 AS 'set_2';")
        expect(result.first['set_1']).to be(1)
        expect do
          @multi_client.next_result
        end.to raise_error(Mysql2::Error)
        expect(@multi_client.next_result).to be false
      end

      it "returns multiple result sets" do
        expect(@multi_client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'").first).to eql('set_1' => 1)

        expect(@multi_client.next_result).to be true
        expect(@multi_client.store_result.first).to eql('set_2' => 2)

        expect(@multi_client.next_result).to be false
      end

      it "should not let query_options mutations affect an already-issued query's later result sets" do
        expect(@multi_client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'").first).to eql('set_1' => 1)

        # Must not leak into the remaining result sets' snapshot.
        @multi_client.query_options[:symbolize_keys] = true

        expect(@multi_client.next_result).to be true
        expect(@multi_client.store_result.first).to eql('set_2' => 2)
      end

      it "does not interfere with other statements" do
        @multi_client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'")
        @multi_client.store_result while @multi_client.next_result

        expect(@multi_client.query("SELECT 3 AS 'next'").first).to eq('next' => 3)
      end

      it "will raise on query if there are outstanding results to read" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")
        expect do
          @multi_client.query("SELECT 4")
        end.to raise_error(Mysql2::Error)
      end

      it "#abandon_results! should work" do
        @multi_client.query("SELECT 1; SELECT 2; SELECT 3")
        @multi_client.abandon_results!
        expect do
          @multi_client.query("SELECT 4")
        end.not_to raise_error
      end

      # Regression coverage for #807 / #962 / #1033: #next_result calls
      # mysql_next_result() directly, which can make a real blocking network
      # read when the next statement in the batch isn't ready yet. Unlike
      # the initial query (see do_query/wait_for_fd in client.c), this read
      # is neither GVL-released nor interruptible.
      it "should not hold the GVL while #next_result waits on a slow next statement" do
        @multi_client.query("SELECT 1 AS a; SELECT SLEEP(1) AS b")

        ticks = 0
        stop = false
        counter = new_thread do
          until stop
            ticks += 1
            sleep 0.01
          end
        end

        @multi_client.next_result
        stop = true
        counter.join

        # ~100 ticks in 1s if the GVL was free to schedule the counter
        # thread on an idle machine; the bug holds the GVL for the entire
        # wait, so ticks stays at exactly 0. GitHub's macOS runners are
        # slow/oversubscribed enough to only deliver ~18-24 in practice
        # (observed in CI), so the threshold has real margin above 0
        # without assuming a well-scheduled machine.
        expect(ticks).to be > 5
      end

      it "should be interruptible via Thread#raise while #next_result waits on a slow next statement" do
        @multi_client.query("SELECT 1 AS a; SELECT SLEEP(2) AS b")

        expect do
          Timeout.timeout(0.3) { @multi_client.next_result }
        end.to raise_error(Timeout::Error)
      end

      it "does not leave the connection claimed after an interrupted #next_result" do
        @multi_client.query("SELECT 1 AS a; SELECT SLEEP(2) AS b")

        expect do
          Timeout.timeout(0.3) { @multi_client.next_result }
        end.to raise_error(Timeout::Error)

        # The interrupted exchange invalidates the connection, same as an
        # interrupted query's read -- so the follow-up query may raise a
        # normal, actionable connection error, or may succeed outright.
        # Either is fine; the one forbidden outcome is a permanently leaked
        # claim, whether reported to another fiber ("in use by") or to this
        # one ("still waiting"). Capture the error, if any, so the assertion
        # runs on every outcome rather than only inside a rescue.
        follow_up_error = begin
          @multi_client.query("SELECT 1")
          nil
        rescue Mysql2::Error => e
          e
        end
        expect(follow_up_error.to_s).not_to match(/This connection is in use by|still waiting for a result/)
      end

      it "releases its claim and keeps the connection usable when #abandon_results! hits a failed statement" do
        @multi_client.query("SELECT 1; SELECT * FROM abandon_no_such_table; SELECT 3")

        expect do
          @multi_client.abandon_results!
        end.to raise_error(Mysql2::Error, /abandon_no_such_table/)

        expect(@multi_client.query("SELECT 4 AS a").first).to eq('a' => 4)
      end

      it "#more_results? should work" do
        @multi_client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'")
        expect(@multi_client.more_results?).to be true

        @multi_client.next_result
        @multi_client.store_result

        expect(@multi_client.more_results?).to be false
      end

      it "should honor :stream for later result sets, not just the first" do
        # Regression coverage for #600: store_result must honor the
        # original query's :stream option for every result set in a
        # multi-statement batch, not just the first.
        #
        # mysql_store_result blocks until the entire result set has
        # arrived; mysql_use_result returns almost immediately and defers
        # the transfer to later row fetches. A large enough second result
        # set creates an unambiguous timing gap between the two: if
        # buffered, store_result itself pays the transfer cost; if
        # streamed, #each pays it instead. (cache_rows: false, size below,
        # chosen so this is quick, but a real dominant-cost gap either way
        # -- not close enough to flake under CI load.)
        @multi_client.query("DROP TABLE IF EXISTS store_result_stream_test")
        @multi_client.query("CREATE TABLE store_result_stream_test (id INT PRIMARY KEY AUTO_INCREMENT, val TEXT)")

        begin
          @multi_client.query(
            "INSERT INTO store_result_stream_test (val) " \
            "SELECT REPEAT('x', 2000) FROM information_schema.columns a, information_schema.columns b LIMIT 60000",
          )

          result = @multi_client.query(
            "SELECT 1 AS a; SELECT * FROM store_result_stream_test",
            stream: true, cache_rows: false,
          )
          result.each { |_r| }

          @multi_client.next_result

          store_result_start = clock_time
          second = @multi_client.store_result
          store_result_time = clock_time - store_result_start

          each_start = clock_time
          second.each { |_r| }
          each_time = clock_time - each_start

          expect(store_result_time).to be < (each_time / 2)
        ensure
          @multi_client.query("DROP TABLE IF EXISTS store_result_stream_test")
        end
      end

      it "#more_results? should work with stored procedures" do
        @multi_client.query("DROP PROCEDURE IF EXISTS test_proc")
        @multi_client.query("CREATE PROCEDURE test_proc() BEGIN SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'; END")
        expect(@multi_client.query("CALL test_proc()").first).to eql('set_1' => 1)
        expect(@multi_client.more_results?).to be true

        @multi_client.next_result
        expect(@multi_client.store_result.first).to eql('set_2' => 2)

        @multi_client.next_result
        expect(@multi_client.store_result).to be_nil # this is the result from CALL itself

        expect(@multi_client.more_results?).to be false
      end
    end
  end

  it "should respond to #socket" do
    expect(@client).to respond_to(:socket)
  end

  if RUBY_PLATFORM =~ /mingw|mswin/
    it "#socket should raise as it's not supported" do
      expect do
        @client.socket
      end.to raise_error(Mysql2::Error, /Raw access to the mysql file descriptor isn't supported on Windows/)
    end
  end

  it "should respond to escape" do
    expect(Mysql2::Client).to respond_to(:escape)
  end

  context "escape" do
    it "should return a new SQL-escape version of the passed string" do
      expect(Mysql2::Client.escape("abc'def\"ghi\0jkl%mno")).to eql("abc\\'def\\\"ghi\\0jkl%mno")
    end

    it "should return the passed string if nothing was escaped" do
      str = "plain"
      expect(Mysql2::Client.escape(str).object_id).to eql(str.object_id)
    end

    it "should not overflow the thread stack" do
      expect do
        new_thread { Mysql2::Client.escape("'" * 256 * 1024) }.join
      end.not_to raise_error
    end

    it "should not overflow the process stack" do
      expect do
        new_thread { Mysql2::Client.escape("'" * 1024 * 1024 * 4) }.join
      end.not_to raise_error
    end

    it "should carry over the original string's encoding" do
      str = "abc'def\"ghi\0jkl%mno".dup
      escaped = Mysql2::Client.escape(str)
      expect(escaped.encoding).to eql(str.encoding)

      str.encode!('us-ascii')
      escaped = Mysql2::Client.escape(str)
      expect(escaped.encoding).to eql(str.encoding)
    end
  end

  it "should respond to #escape" do
    expect(@client).to respond_to(:escape)
  end

  context "#escape" do
    it "should return a new SQL-escape version of the passed string" do
      expect(@client.escape("abc'def\"ghi\0jkl%mno")).to eql("abc\\'def\\\"ghi\\0jkl%mno")
    end

    it "should return the passed string if nothing was escaped" do
      str = "plain"
      expect(@client.escape(str).object_id).to eql(str.object_id)
    end

    it "should not overflow the thread stack" do
      expect do
        new_thread { @client.escape("'" * 256 * 1024) }.join
      end.not_to raise_error
    end

    it "should not overflow the process stack" do
      expect do
        new_thread { @client.escape("'" * 1024 * 1024 * 4) }.join
      end.not_to raise_error
    end

    it "should require an open connection" do
      @client.close
      expect do
        @client.escape ""
      end.to raise_error(Mysql2::Error)
    end

    it "should not tag escaped binary data with the connection's encoding" do
      client = new_client(encoding: 'utf8mb4')

      # Two 16-byte binary strings, neither valid UTF-8. One happens to contain
      # a byte mysql_real_escape_string escapes, the other doesn't -- both
      # should come back tagged as binary, not silently promoted to UTF-8.
      no_escaping_needed = ['bafe80143bbe4bd3ba785d0679192fbf'].pack('H*')
      escaping_needed = ['6614ed2fb7e749cda6caab6ca6b34dcc'].pack('H*')

      expect(client.escape(no_escaping_needed).encoding).to eql(Encoding::ASCII_8BIT)

      escaped = client.escape(escaping_needed)
      expect(escaped.encoding).to eql(Encoding::ASCII_8BIT)
      expect(escaped.valid_encoding?).to be true
    end

    context 'under NO_BACKSLASH_ESCAPES sql_mode' do
      before(:example) do
        @client.query("SET SESSION sql_mode = concat(@@sql_mode, ',NO_BACKSLASH_ESCAPES')")
      end

      it "should escape correctly (round-tripping through a real query) or raise Mysql2::Error -- never a bare ArgumentError" do
        begin
          escaped = @client.escape("it's \\a\\ test")
          row = @client.query("SELECT '#{escaped}' AS x").first
          expect(row['x']).to eq("it's \\a\\ test")
        rescue Mysql2::Error
          # Acceptable on client libraries that genuinely can't escape safely
          # under this SQL mode (see ESCAPE_QUOTE_SUPPORTED). Anything other
          # than Mysql2::Error -- e.g. the ArgumentError this regresses --
          # propagates and fails this example.
        end
      end
    end

    context 'when mysql encoding is not utf8' do
      let(:client) { new_client(encoding: "ujis") }

      it 'should return a internal encoding string if Encoding.default_internal is set' do
        with_internal_encoding Encoding::UTF_8 do
          expect(client.escape("\u{30C6}\u{30B9}\u{30C8}")).to eq "\u{30C6}\u{30B9}\u{30C8}"
          expect(client.escape("\u{30C6}'\u{30B9}\"\u{30C8}")).to eq "\u{30C6}\\'\u{30B9}\\\"\u{30C8}"
        end
      end
    end
  end

  it "should respond to #info" do
    expect(@client).to respond_to(:info)
  end

  it "#info should return a hash containing the client version ID and String" do
    info = @client.info
    expect(info).to be_an_instance_of(Hash)
    expect(info).to have_key(:id)
    expect(info[:id]).to be_an_instance_of(0.class)
    expect(info).to have_key(:version)
    expect(info[:version]).to be_an_instance_of(String)
  end

  context "strings returned by #info" do
    it "should be tagged as ascii" do
      expect(@client.info[:version].encoding).to eql(Encoding::US_ASCII)
      expect(@client.info[:header_version].encoding).to eql(Encoding::US_ASCII)
    end
  end

  context "strings returned by .info" do
    it "should be tagged as ascii" do
      expect(Mysql2::Client.info[:version].encoding).to eql(Encoding::US_ASCII)
      expect(Mysql2::Client.info[:header_version].encoding).to eql(Encoding::US_ASCII)
    end
  end

  it "should respond to #server_info" do
    expect(@client).to respond_to(:server_info)
  end

  it "#server_info should return a hash containing the client version ID and String" do
    server_info = @client.server_info
    expect(server_info).to be_an_instance_of(Hash)
    expect(server_info).to have_key(:id)
    expect(server_info[:id]).to be_an_instance_of(0.class)
    expect(server_info).to have_key(:version)
    expect(server_info[:version]).to be_an_instance_of(String)
  end

  it "#server_info should require an open connection" do
    @client.close
    expect do
      @client.server_info
    end.to raise_error(Mysql2::Error)
  end

  context "strings returned by #server_info" do
    it "should default to the connection's encoding if Encoding.default_internal is nil" do
      with_internal_encoding nil do
        expect(@client.server_info[:version].encoding).to eql(Encoding::UTF_8)

        client2 = new_client(encoding: 'ascii')
        expect(client2.server_info[:version].encoding).to eql(Encoding::ASCII)
      end
    end

    it "should use Encoding.default_internal" do
      with_internal_encoding Encoding::UTF_8 do
        expect(@client.server_info[:version].encoding).to eql(Encoding.default_internal)
      end

      with_internal_encoding Encoding::ASCII do
        expect(@client.server_info[:version].encoding).to eql(Encoding.default_internal)
      end
    end
  end

  it "should raise a Mysql2::Error::ConnectionError exception upon connection failure due to invalid credentials" do
    expect do
      begin
        new_client(host: 'localhost', username: 'asdfasdf8d2h', password: 'asdfasdfw42')
      rescue Mysql2::Error => e
        raise unless e.message.include?('mysql_native_password')

        skip("Native password is not supported")
      end
    end.to raise_error(Mysql2::Error::ConnectionError)

    expect do
      new_client(DatabaseCredentials['root'])
    end.not_to raise_error
  end

  context 'write operations api' do
    before(:example) do
      @client.query "USE test"
      @client.query "CREATE TABLE IF NOT EXISTS lastIdTest (`id` BIGINT NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))"
    end

    after(:example) do
      @client.query "DROP TABLE lastIdTest"
    end

    it "should respond to #last_id" do
      expect(@client).to respond_to(:last_id)
    end

    it "#last_id should return a Fixnum, from the last INSERT/UPDATE" do
      expect(@client.last_id).to eql(0)
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      expect(@client.last_id).to eql(1)
    end

    it "should respond to #last_id" do
      expect(@client).to respond_to(:last_id)
    end

    it "#last_id should handle BIGINT auto-increment ids above 32 bits" do
      # The id column type must be BIGINT. Surprise: INT(x) is limited to 32-bits for all values of x.
      # Insert a row with a given ID, this should raise the auto-increment state
      @client.query "INSERT INTO lastIdTest (id, blah) VALUES (5000000000, 5000)"
      expect(@client.last_id).to eql(5000000000)
      @client.query "INSERT INTO lastIdTest (blah) VALUES (5001)"
      expect(@client.last_id).to eql(5000000001)
    end

    it "#last_id isn't cleared by Statement#close" do
      stmt = @client.prepare("INSERT INTO lastIdTest (blah) VALUES (1234)")

      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      expect(@client.last_id).to eql(1)

      stmt.close

      expect(@client.last_id).to eql(1)
    end

    it "#affected_rows should return a Fixnum, from the last INSERT/UPDATE" do
      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234), (5678)"
      expect(@client.affected_rows).to eql(2)
      @client.query "UPDATE lastIdTest SET blah=4321 WHERE id=1"
      expect(@client.affected_rows).to eql(1)
    end

    it "#affected_rows with multi statements returns the last result's affected_rows" do
      begin
        @client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_ON)
        @client.query("INSERT INTO lastIdTest (blah) VALUES (1234), (5678); UPDATE lastIdTest SET blah=4321 WHERE id=1")
        expect(@client.affected_rows).to eq(2)
        expect(@client.next_result).to eq(true)
        expect(@client.affected_rows).to eq(1)
      ensure
        @client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_OFF)
      end
    end

    it "#affected_rows isn't cleared by Statement#close" do
      stmt = @client.prepare("INSERT INTO lastIdTest (blah) VALUES (1234)")

      @client.query "INSERT INTO lastIdTest (blah) VALUES (1234)"
      expect(@client.affected_rows).to eql(1)

      stmt.close

      expect(@client.affected_rows).to eql(1)
    end
  end

  it "#affected_rows when no rows were affected returns 1" do
    @client.query "SELECT sleep(0.01)"
    expect(@client.affected_rows).to eq(1)
  end

  it "should respond to #thread_id" do
    expect(@client).to respond_to(:thread_id)
  end

  it "#thread_id should be a Fixnum" do
    expect(@client.thread_id).to be_an_instance_of(0.class)
  end

  it "should respond to #ping" do
    expect(@client).to respond_to(:ping)
  end

  context "session_track" do
    before(:example) do
      unless Mysql2::Client.const_defined?(:SESSION_TRACK)
        skip('Server versions must be MySQL 5.7 later.')
      end
      @client.query("SET @@SESSION.session_track_system_variables='*';")
    end

    it "returns changes system variables for SESSION_TRACK_SYSTEM_VARIABLES" do
      @client.query("SET @@SESSION.session_track_state_change=ON;")
      res = @client.session_track(Mysql2::Client::SESSION_TRACK_SYSTEM_VARIABLES)
      expect(res).to include("session_track_state_change", "ON")
    end

    it "returns database name for SESSION_TRACK_SCHEMA" do
      @client.query("USE information_schema")
      res = @client.session_track(Mysql2::Client::SESSION_TRACK_SCHEMA)
      expect(res).to eq(["information_schema"])
    end

    it "returns multiple session track type values when available" do
      @client.query("SET @@SESSION.session_track_transaction_info='CHARACTERISTICS';")

      res = @client.session_track(Mysql2::Client::SESSION_TRACK_SYSTEM_VARIABLES)
      expect(res).to include("session_track_transaction_info", "CHARACTERISTICS")

      res = @client.session_track(Mysql2::Client::SESSION_TRACK_STATE_CHANGE)
      expect(res).to be_nil

      res = @client.session_track(Mysql2::Client::SESSION_TRACK_TRANSACTION_CHARACTERISTICS)
      expect(res).to include("")
    end

    it "returns valid transaction state inside a transaction" do
      @client.query("SET @@SESSION.session_track_transaction_info='CHARACTERISTICS'")
      @client.query("START TRANSACTION")

      res = @client.session_track(Mysql2::Client::SESSION_TRACK_TRANSACTION_STATE)
      expect(res).to include("T_______")
    end

    it "returns empty array if session track type not found" do
      @client.query("SET @@SESSION.session_track_state_change=ON;")
      res = @client.session_track(Mysql2::Client::SESSION_TRACK_TRANSACTION_CHARACTERISTICS)
      expect(res).to be_nil
    end
  end

  context "select_db" do
    before(:example) do
      2.times do |i|
        @client.query("CREATE DATABASE test_selectdb_#{i}")
        @client.query("USE test_selectdb_#{i}")
        @client.query("CREATE TABLE test#{i} (`id` int NOT NULL PRIMARY KEY)")
      end
    end

    after(:example) do
      2.times do |i|
        @client.query("DROP DATABASE test_selectdb_#{i}")
      end
    end

    it "should respond to #select_db" do
      expect(@client).to respond_to(:select_db)
    end

    it "should switch databases" do
      @client.select_db("test_selectdb_0")
      expect(@client.query("SHOW TABLES").first.values.first).to eql("test0")
      @client.select_db("test_selectdb_1")
      expect(@client.query("SHOW TABLES").first.values.first).to eql("test1")
      @client.select_db("test_selectdb_0")
      expect(@client.query("SHOW TABLES").first.values.first).to eql("test0")
    end

    it "should raise a Mysql2::Error when the database doesn't exist" do
      expect do
        @client.select_db("nopenothere")
      end.to raise_error(Mysql2::Error)
    end

    it "should return the database switched to" do
      expect(@client.select_db("test_selectdb_1")).to eq("test_selectdb_1")
    end

    it "should switch databases correctly under GC.stress with a name past Ruby's embedded-string threshold" do
      # Regression coverage for #822: rb_mysql_client_select_db extracts a
      # raw C pointer from the `db` String argument (StringValueCStr) and
      # hands it to nogvl_select_db with the GVL released, without an
      # RB_GC_GUARD -- the same hazard fixed elsewhere in this file (see
      # #1504). Names at or past MRI's embedded-string length (23 bytes on
      # 64-bit builds) move to a separately allocated buffer, which is what
      # a premature GC could free out from under the still-in-use pointer;
      # shorter, embedded names don't have a separate buffer to free, which
      # is why this was so hard to pin down originally. A freshly allocated,
      # unfrozen String is used each iteration so nothing else roots it.
      long_name = "test_selectdb_stress_#{'x' * 10}"
      @client.query("DROP DATABASE IF EXISTS #{long_name}")
      @client.query("CREATE DATABASE #{long_name}")

      begin
        GC.stress = true
        20.times do
          name = long_name.dup
          @client.select_db(name)
          expect(@client.query("SELECT DATABASE() AS d").first["d"]).to eq(long_name)
        end
      ensure
        GC.stress = false
        @client.query("USE test")
        @client.query("DROP DATABASE IF EXISTS #{long_name}")
      end
    end
  end

  context 'database' do
    before(:example) do
      2.times do |i|
        @client.query("CREATE DATABASE test_db#{i}")
      end
    end

    after(:example) do
      2.times do |i|
        @client.query("DROP DATABASE test_db#{i}")
      end
    end

    it "should be `nil` when no database is selected" do
      client = new_client(database: nil)
      expect(client.database).to eq(nil)
    end

    it "should reflect the initially connected database" do
      client = new_client(database: 'test_db0')
      expect(client.database).to eq('test_db0')
    end

    context "when session tracking is on" do
      it "should change to reflect currently selected database" do
        client = new_client(database: 'test_db0')
        client.query('SET session_track_schema=on')
        expect { client.query('USE test_db1') }.to change {
          client.database
        }.from('test_db0').to('test_db1')
      end
    end

    context "when session tracking is off" do
      it "does not change when a new database is selected" do
        client = new_client(database: 'test_db0')
        client.query('SET session_track_schema=off')
        expect(client.database).to eq('test_db0')
        expect { client.query('USE test_db1') }.not_to(change { client.database })
      end
    end
  end

  it "#thread_id should return a boolean" do
    expect(@client.ping).to eql(true)
    @client.close
    expect(@client.ping).to eql(false)
  end

  it "should be able to connect using plaintext password" do
    client = new_client(enable_cleartext_plugin: true)
    client.query('SELECT 1')
  end

  it "should accept the tls_sni_name option" do
    skip("DON'T WORRY, THIS TEST PASSES - but this mysql client library does not support tls_sni_name.") unless Mysql2::Client::TLS_SNI_SUPPORTED

    expect do
      client = new_client(tls_sni_name: 'db.example.com')
      client.query('SELECT 1')
    end.not_to raise_error
  end

  it "should raise when the tls_sni_name option is unsupported" do
    skip("DON'T WORRY, THIS TEST PASSES - but this mysql client library supports tls_sni_name.") if Mysql2::Client::TLS_SNI_SUPPORTED

    expect do
      new_client(tls_sni_name: 'db.example.com')
    end.to raise_error(Mysql2::Error, /tls_sni_name/)
  end

  it "should respond to #encoding" do
    expect(@client).to respond_to(:encoding)
  end

  it "should not include the password in the output of #inspect" do
    client_class = Class.new(Mysql2::Client) do
      def connect(*args); end
    end

    client = client_class.new(password: "secretsecret")

    expect(client.inspect).not_to include("password")
    expect(client.inspect).not_to include("secretsecret")

    expect do
      client = client_class.new(pass: "secretsecret")
    end.to output(/WARNING/).to_stderr

    expect(client.inspect).not_to include("pass")
    expect(client.inspect).not_to include("secretsecret")
  end

  it "should not allow concurrent use of #ping" do
    @client.ping
    thread = new_thread { @client.query("SELECT SLEEP(1)") }
    thread.join(0.1)
    10.times do
      expect do
        @client.ping
      end.to raise_error(Mysql2::Error, /This connection is in use by/)
    end
    expect(thread.value.to_a).to eq([{ "SLEEP(1)" => 0 }])
    expect(@client.ping).to eq(true)
  end

  it "should not allow concurrent use of #close" do
    @client.ping
    thread = new_thread { @client.query("SELECT SLEEP(1)") }
    thread.join(0.1)
    10.times do
      expect do
        @client.close
      end.to raise_error(Mysql2::Error, /This connection is in use by/)
    end
    expect(thread.value.to_a).to eq([{ "SLEEP(1)" => 0 }])
    expect(@client.close).to be_nil
  end

  it "should not allow concurrent use of #select_db" do
    thread = new_thread { @client.query("SELECT SLEEP(1)") }
    thread.join(0.1)
    expect do
      @client.select_db(DatabaseCredentials['root']['database'])
    end.to raise_error(Mysql2::Error, /This connection is in use by/)
    expect(thread.value.to_a).to eq([{ "SLEEP(1)" => 0 }])
    expect(@client.select_db(DatabaseCredentials['root']['database'])).to eq(DatabaseCredentials['root']['database'])
  end

  it "should not allow concurrent use of #next_result" do
    thread = new_thread { @client.query("SELECT SLEEP(1)") }
    thread.join(0.1)
    expect do
      @client.next_result
    end.to raise_error(Mysql2::Error, /This connection is in use by/)
    expect(thread.value.to_a).to eq([{ "SLEEP(1)" => 0 }])
    expect(@client.next_result).to be false
  end

  it "should not allow concurrent use of #store_result" do
    thread = new_thread { @client.query("SELECT SLEEP(1)") }
    thread.join(0.1)
    expect do
      @client.store_result
    end.to raise_error(Mysql2::Error, /This connection is in use by/)
    expect(thread.value.to_a).to eq([{ "SLEEP(1)" => 0 }])
    expect(@client.query("SELECT 1 AS a").first).to eq('a' => 1)
  end

  it "should not allow concurrent use of #abandon_results!" do
    thread = new_thread { @client.query("SELECT SLEEP(1)") }
    thread.join(0.1)
    expect do
      @client.abandon_results!
    end.to raise_error(Mysql2::Error, /This connection is in use by/)
    expect(thread.value.to_a).to eq([{ "SLEEP(1)" => 0 }])
    expect(@client.abandon_results!).to be_nil
  end

  it "should not allow concurrent use of #set_server_option" do
    thread = new_thread { @client.query("SELECT SLEEP(1)") }
    thread.join(0.1)
    expect do
      @client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_ON)
    end.to raise_error(Mysql2::Error, /This connection is in use by/)
    expect(thread.value.to_a).to eq([{ "SLEEP(1)" => 0 }])
    expect(@client.set_server_option(Mysql2::Client::OPTION_MULTI_STATEMENTS_OFF)).to be true
  end

  context "#ping interrupted mid-flight" do
    # Regression coverage for #777 -- see do_ping in client.c for the
    # mechanism this protects against.
    #
    # A tiny TCP pass-through proxy lets us freeze the server's response to
    # #ping on command, giving Thread#raise a real blocking window to land
    # in -- something a real, fast localhost round-trip can't reliably
    # provide.
    class FreezableProxy
      def initialize(real_host, real_port)
        @server = TCPServer.new('127.0.0.1', 0)
        @real_host = real_host
        @real_port = real_port
        @frozen = false
        @mutex = Mutex.new
        @threads = []
      end

      def port
        @server.addr[1]
      end

      def freeze!
        @mutex.synchronize { @frozen = true }
      end

      def unfreeze!
        @mutex.synchronize { @frozen = false }
      end

      def frozen?
        @mutex.synchronize { @frozen }
      end

      def run
        @threads << Thread.new do
          loop do
            client_sock = @server.accept
            @threads << Thread.new(client_sock) { |cs| handle(cs) }
          end
        end
      end

      def handle(client_sock)
        upstream = TCPSocket.new(@real_host, @real_port)
        [
          Thread.new { pump(client_sock, upstream) },
          Thread.new { pump(upstream, client_sock) },
        ].each { |t| @threads << t }.each(&:join)
      ensure
        begin
          client_sock.close
        rescue StandardError
          nil
        end
        begin
          upstream.close
        rescue StandardError
          nil
        end
      end

      def pump(src, dst)
        loop do
          data = src.readpartial(4096)
          sleep 0.01 while frozen?
          dst.write(data)
        end
      rescue IOError, Errno::ECONNRESET
        nil
      end

      def shutdown
        @threads.each(&:kill)
        @server.close
      rescue IOError
        nil
      end
    end

    class SimulatedWatchdogInterrupt < StandardError; end

    it "does not permanently lock the connection when #ping is interrupted" do
      # do_ping's rb_rescue2/disconnect_and_raise protection is #ifndef
      # _WIN32 -- same as #query's own interrupt-safety a few lines up in
      # client.c -- so on Windows this scenario still reproduces #777.
      skip "not fixed on Windows -- see do_ping in client.c" if RUBY_PLATFORM =~ /mingw|mswin/

      creds = DatabaseCredentials['root']
      proxy = FreezableProxy.new(creds['host'], creds['port'] || 3306)
      proxy.run
      sleep 0.1 # let the accept loop start

      client = new_client('host' => '127.0.0.1', 'port' => proxy.port)

      begin
        proxy.freeze!
        # Not new_thread: this thread is expected to die from the raise
        # below, and Thread#join re-raises a dead thread's exception on
        # every call -- including the after(:example) hook's cleanup join
        # on every tracked thread, which would fail the example a second
        # time after we've already handled it here.
        thread = Thread.new { client.ping }
        thread.report_on_exception = false
        thread.join(0.3) # ping is now blocked inside the frozen read

        thread.raise(SimulatedWatchdogInterrupt)
        sleep 0.2
        proxy.unfreeze! # let the blocked read resolve so the pending raise can land

        expect { thread.join(5) }.to raise_error(SimulatedWatchdogInterrupt)

        # The interrupted ping correctly leaves the connection recognized as
        # disconnected -- ping returns false, not the permanent
        # "This connection is in use by" lockout the bug caused.
        expect(client.ping).to eq(false)
      ensure
        begin
          client.close
        rescue StandardError
          nil
        end
        proxy.shutdown
      end
    end
  end

  context "Thread#exit mid-query" do
    # Regression coverage for #1392: query()'s send/wait phases (do_send_query,
    # do_query) were only protected by rb_rescue2, which catches ordinary
    # Ruby exceptions but not Thread#exit's non-exception unwind -- so an
    # exited thread's cleanup (clearing active_fiber) never ran, leaving the
    # connection permanently stuck reporting "This connection is in use by:
    # <dead fiber>" for every future caller, even the interrupted thread's
    # own client object being reused later (e.g. from an ActiveRecord pool).
    #
    # Reuses FreezableProxy (defined above, in the #ping interrupted mid-flight
    # context) to reliably keep the query in flight when we call Thread#exit,
    # rather than racing a fast localhost round-trip.
    it "does not permanently lock the connection when Thread#exit interrupts a query" do
      # rb_mysql_query's rb_ensure protection around do_send_query/do_query is
      # #ifndef _WIN32 -- same as do_ping's rb_rescue2/disconnect_and_raise a
      # few lines down in client.c -- so on Windows this scenario still
      # reproduces #1392.
      skip "not fixed on Windows -- see rb_mysql_query in client.c" if RUBY_PLATFORM =~ /mingw|mswin/

      creds = DatabaseCredentials['root']
      proxy = FreezableProxy.new(creds['host'], creds['port'] || 3306)
      proxy.run
      sleep 0.1 # let the accept loop start

      client = new_client('host' => '127.0.0.1', 'port' => proxy.port)

      begin
        proxy.freeze!
        thread = Thread.new { client.query("SELECT 1") }
        thread.report_on_exception = false
        thread.join(0.3) # query is now blocked inside the frozen response

        thread.exit
        thread.join(2)

        # The interrupted query must not leave the connection permanently
        # marked busy -- the follow-up query may raise a normal, actionable
        # connection error or may succeed, but must never report "This
        # connection is in use by" (a dead fiber, forever). Capture the
        # error, if any, so the assertion runs on every outcome rather than
        # only inside a rescue.
        follow_up_error = begin
          client.query("SELECT 1")
          nil
        rescue Mysql2::Error => e
          e
        end
        expect(follow_up_error.to_s).not_to match(/This connection is in use by/)
      ensure
        begin
          client.close
        rescue StandardError
          nil
        end
        proxy.shutdown
      end
    end
  end
end
