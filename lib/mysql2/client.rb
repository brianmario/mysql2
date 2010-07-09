module Mysql2
  class Client
    def initialize opts = {}
      init_connection

      [:reconnect, :connect_timeout].each do |key|
        next unless opts.key?(key)
        send(:"#{key}=", opts[key])
      end
      # force the encoding to utf8
      self.charset_name = opts[:encoding] || 'utf8'

      ssl_set(*opts.values_at(:sslkey, :sslcert, :sslca, :sslcapath, :sslciper))

      user     = opts[:username]
      pass     = opts[:password]
      host     = opts[:host] || 'localhost'
      port     = opts[:port] || 3306
      database = opts[:database]
      socket   = opts[:socket]

      connect user, pass, host, port, database, socket
    end

    # NOTE: from ruby-mysql
    if defined? Encoding
      CHARSET_MAP = {
        "armscii8" => nil,
        "ascii"    => Encoding::US_ASCII,
        "big5"     => Encoding::Big5,
        "binary"   => Encoding::ASCII_8BIT,
        "cp1250"   => Encoding::Windows_1250,
        "cp1251"   => Encoding::Windows_1251,
        "cp1256"   => Encoding::Windows_1256,
        "cp1257"   => Encoding::Windows_1257,
        "cp850"    => Encoding::CP850,
        "cp852"    => Encoding::CP852,
        "cp866"    => Encoding::IBM866,
        "cp932"    => Encoding::Windows_31J,
        "dec8"     => nil,
        "eucjpms"  => Encoding::EucJP_ms,
        "euckr"    => Encoding::EUC_KR,
        "gb2312"   => Encoding::EUC_CN,
        "gbk"      => Encoding::GBK,
        "geostd8"  => nil,
        "greek"    => Encoding::ISO_8859_7,
        "hebrew"   => Encoding::ISO_8859_8,
        "hp8"      => nil,
        "keybcs2"  => nil,
        "koi8r"    => Encoding::KOI8_R,
        "koi8u"    => Encoding::KOI8_U,
        "latin1"   => Encoding::ISO_8859_1,
        "latin2"   => Encoding::ISO_8859_2,
        "latin5"   => Encoding::ISO_8859_9,
        "latin7"   => Encoding::ISO_8859_13,
        "macce"    => Encoding::MacCentEuro,
        "macroman" => Encoding::MacRoman,
        "sjis"     => Encoding::SHIFT_JIS,
        "swe7"     => nil,
        "tis620"   => Encoding::TIS_620,
        "ucs2"     => Encoding::UTF_16BE,
        "ujis"     => Encoding::EucJP_ms,
        "utf8"     => Encoding::UTF_8,
      }

      def self.encoding_from_charset(charset)
        charset = charset.to_s.downcase
        enc = CHARSET_MAP[charset]
        raise Mysql2::Error, "unsupported charset: #{charset}" unless enc
        enc
      end
    end
  end
end
