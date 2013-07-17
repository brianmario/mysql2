# encoding: UTF-8
require 'spec_helper'

describe Mysql2::Error do
  before(:each) do
    begin
      @err_client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "utf8"))
      @err_client.query("HAHAHA")
    rescue Mysql2::Error => e
      @error = e
    ensure
      @err_client.close
    end

    begin
      @err_client2 = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "big5"))
      @err_client2.query("HAHAHA")
    rescue Mysql2::Error => e
      @error2 = e
    ensure
      @err_client2.close
    end
  end

  test "responds to #error_number" do
    assert @error.respond_to?(:error_number)
  end

  test "responds to #sql_state" do
    assert @error.respond_to?(:sql_state)
  end

  # Mysql gem compatibility
  test "aliases #error_number to #errno" do
    assert @error.respond_to?(:errno)
  end

  test "aliases #message to #error" do
    assert @error.respond_to?(:error)
  end

  unless RUBY_VERSION =~ /1.8/
    test "#message encoding matches the connection's encoding, or Encoding.default_internal if set" do
      if Encoding.default_internal.nil?
        assert_equal @err_client.encoding, @error.message.encoding
        assert_equal @err_client2.encoding, @error2.message.encoding
      else
        assert_equal Encoding.default_internal, @error.message.encoding
        assert_equal Encoding.default_internal, @error2.message.encoding
      end
    end

    test "#error encoding matches the connection's encoding, or Encoding.default_internal if set" do
      if Encoding.default_internal.nil?
        assert_equal @err_client.encoding, @error.error.encoding
        assert_equal @err_client2.encoding, @error2.error.encoding
      else
        assert_equal Encoding.default_internal, @error.error.encoding
        assert_equal Encoding.default_internal, @error2.error.encoding
      end
    end

    test "#sql_state encoding matches the connection's encoding, or Encoding.default_internal if set" do
      if Encoding.default_internal.nil?
        assert_equal @err_client.encoding, @error.sql_state.encoding
        assert_equal @err_client2.encoding, @error2.sql_state.encoding
      else
        assert_equal Encoding.default_internal, @error.sql_state.encoding
        assert_equal Encoding.default_internal, @error2.sql_state.encoding
      end
    end
  end
end
