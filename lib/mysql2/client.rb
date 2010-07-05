module Mysql2
  class Client
    def initialize opts = {}
      init_connection

      [:reconnect, :connect_timeout].each do |key|
        next unless opts.key?(key)
        send(:"#{key}=", opts[key])
      end
      # force the encoding to utf8
      self.charset_name = 'utf8'

      ssl_set(*opts.values_at(:sslkey, :sslcert, :sslca, :sslcapath, :sslciper))

      user     = opts[:username]
      pass     = opts[:password]
      host     = opts[:host] || 'localhost'
      port     = opts[:port] || 3306
      database = opts[:database]
      socket   = opts[:socket]

      connect user, pass, host, port, database, socket
    end
  end
end
