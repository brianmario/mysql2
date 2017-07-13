# encoding: UTF-8

module Mysql2
  class Error < StandardError
    ENCODE_OPTS = {
      :undef => :replace,
      :invalid => :replace,
      :replace => '?'.freeze,
    }.freeze

    ConnectionError = Class.new(Error)
    TimeoutError = Class.new(Error)

    CODES = {
      1205 => TimeoutError, # ER_LOCK_WAIT_TIMEOUT
    }

    [
      1044, # ER_DBACCESS_DENIED_ERROR
      1045, # ER_ACCESS_DENIED_ERROR
      1152, # ER_ABORTING_CONNECTION
      1153, # ER_NET_PACKET_TOO_LARGE
      1154, # ER_NET_READ_ERROR_FROM_PIPE
      1155, # ER_NET_FCNTL_ERROR
      1156, # ER_NET_PACKETS_OUT_OF_ORDER
      1157, # ER_NET_UNCOMPRESS_ERROR
      1158, # ER_NET_READ_ERROR
      1159, # ER_NET_READ_INTERRUPTED
      1160, # ER_NET_ERROR_ON_WRITE
      1161, # ER_NET_WRITE_INTERRUPTED

      2001, # CR_SOCKET_CREATE_ERROR
      2002, # CR_CONNECTION_ERROR
      2003, # CR_CONN_HOST_ERROR
      2004, # CR_IPSOCK_ERROR
      2005, # CR_UNKNOWN_HOST
      2006, # CR_SERVER_GONE_ERROR
      2007, # CR_VERSION_ERROR
      2009, # CR_WRONG_HOST_INFO
      2012, # CR_SERVER_HANDSHAKE_ERR
      2013, # CR_SERVER_LOST
      2020, # CR_NET_PACKET_TOO_LARGE
      2026, # CR_SSL_CONNECTION_ERROR
      2027, # CR_MALFORMED_PACKET
      2047, # CR_CONN_UNKNOW_PROTOCOL
      2048, # CR_INVALID_CONN_HANDLE
      2049, # CR_UNUSED_1
    ].each { |c| CODES[c] = ConnectionError }

    CODES.freeze

    attr_reader :error_number, :sql_state

    # Mysql gem compatibility
    alias_method :errno, :error_number
    alias_method :error, :message

    def initialize(msg, server_version = nil, error_number = nil, sql_state = nil)
      @server_version = server_version
      @error_number = error_number
      @sql_state = sql_state.respond_to?(:encode) ? sql_state.encode(ENCODE_OPTS) : sql_state

      super(clean_message(msg))
    end

    def self.new_with_args(msg, server_version, error_number, sql_state)
      error_class = CODES.fetch(error_number, self)
      error_class.new(msg, server_version, error_number, sql_state)
    end

    private

    # In MySQL 5.5+ error messages are always constructed server-side as UTF-8
    # then returned in the encoding set by the `character_set_results` system
    # variable.
    #
    # See http://dev.mysql.com/doc/refman/5.5/en/charset-errors.html for
    # more context.
    #
    # Before MySQL 5.5 error message template strings are in whatever encoding
    # is associated with the error message language.
    # See http://dev.mysql.com/doc/refman/5.1/en/error-message-language.html
    # for more information.
    #
    # The issue is that the user-data inserted in the message could potentially
    # be in any encoding MySQL supports and is insert into the latin1, euckr or
    # koi8r string raw. Meaning there's a high probability the string will be
    # corrupt encoding-wise.
    #
    # See http://dev.mysql.com/doc/refman/5.1/en/charset-errors.html for
    # more information.
    #
    # So in an attempt to make sure the error message string is always in a valid
    # encoding, we'll assume UTF-8 and clean the string of anything that's not a
    # valid UTF-8 character.
    #
    # Except for if we're on 1.8, where we'll do nothing ;)
    #
    # Returns a valid UTF-8 string in Ruby 1.9+, the original string on Ruby 1.8
    def clean_message(message)
      return message unless message.respond_to?(:encode)

      if @server_version && @server_version > 50500
        message.encode(ENCODE_OPTS)
      else
        message.encode(Encoding::UTF_8, ENCODE_OPTS)
      end
    end
  end
end
