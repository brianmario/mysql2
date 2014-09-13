# encoding: UTF-8

module Mysql2
  class Error < StandardError
    REPLACEMENT_CHAR = '?'
    ENCODE_OPTS      = {:undef => :replace, :invalid => :replace, :replace => REPLACEMENT_CHAR}

    attr_accessor :error_number
    attr_reader   :sql_state
    attr_writer   :server_version

    # Mysql gem compatibility
    alias_method :errno, :error_number
    alias_method :error, :message

    def initialize(msg, server_version=nil)
      self.server_version = server_version

      super(clean_message(msg))
    end

    def sql_state=(state)
      @sql_state = ''.respond_to?(:encode) ? state.encode(ENCODE_OPTS) : state
    end

    private

    # In MySQL 5.5+ error messages are always constructed server-side as UTF-8
    # then returned in the encoding set by the `character_set_results` system
    # variable.
    #
    # See http://dev.mysql.com/doc/refman/5.5/en/charset-errors.html for
    # more contetx.
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
      return message if !message.respond_to?(:encoding)

      if @server_version && @server_version > 50500
        message.encode(ENCODE_OPTS)
      else
        if message.respond_to? :scrub
          message.scrub(REPLACEMENT_CHAR).encode(ENCODE_OPTS)
        else
          # This is ugly as hell but Ruby 1.9 doesn't provide a way to clean a string
          # and retain it's valid UTF-8 characters, that I know of.

          new_message = "".force_encoding(Encoding::UTF_8)
          message.chars.each do |char|
            if char.valid_encoding?
              new_message << char
            else
              new_message << REPLACEMENT_CHAR
            end
          end
          new_message.encode(ENCODE_OPTS)
        end
      end
    end
  end
end
