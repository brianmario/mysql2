# encoding: UTF-8

require 'spec_helper'

RSpec.describe Mysql2::Error do
  let(:client) { Mysql2::Client.new(DatabaseCredentials['root']) }

  let :error do
    begin
      client.query("HAHAHA")
    rescue Mysql2::Error => e
      error = e
    ensure
      client.close
    end

    error
  end

  it "responds to error_number and sql_state, with aliases" do
    expect(error).to respond_to(:error_number)
    expect(error).to respond_to(:sql_state)

    # Mysql gem compatibility
    expect(error).to respond_to(:errno)
    expect(error).to respond_to(:error)
  end

  if "".respond_to? :encoding
    let :error do
      client = Mysql2::Client.new(DatabaseCredentials['root'])
      begin
        client.query("\xE9\x80\xA0\xE5\xAD\x97")
      rescue Mysql2::Error => e
        error = e
      ensure
        client.close
      end

      error
    end

    let :bad_err do
      client = Mysql2::Client.new(DatabaseCredentials['root'])
      begin
        client.query("\xE5\xC6\x7D\x1F")
      rescue Mysql2::Error => e
        error = e
      ensure
        client.close
      end

      error
    end

    it "returns error messages as UTF-8 by default" do
      with_internal_encoding nil do
        expect(error.message.encoding).to eql(Encoding::UTF_8)
        error.message.valid_encoding?

        expect(bad_err.message.encoding).to eql(Encoding::UTF_8)
        bad_err.message.valid_encoding?

        expect(bad_err.message).to include("??}\u001F")
      end
    end

    it "returns sql state as ASCII" do
      expect(error.sql_state.encoding).to eql(Encoding::US_ASCII)
      error.sql_state.valid_encoding?
    end

    it "returns error messages and sql state in Encoding.default_internal if set" do
      with_internal_encoding 'UTF-16LE' do
        expect(error.message.encoding).to eql(Encoding.default_internal)
        error.message.valid_encoding?

        expect(bad_err.message.encoding).to eql(Encoding.default_internal)
        bad_err.message.valid_encoding?
      end
    end
  end
end
