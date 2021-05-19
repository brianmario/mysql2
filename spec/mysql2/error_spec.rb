require 'spec_helper'

RSpec.describe Mysql2::Error do
  let(:error) do
    begin
      @client.query("HAHAHA")
    rescue Mysql2::Error => e
      error = e
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

  context 'encoding' do
    let(:valid_utf8) { '造字' }
    let(:error) do
      begin
        @client.query(valid_utf8)
      rescue Mysql2::Error => e
        e
      end
    end

    let(:invalid_utf8) { ["e5c67d1f"].pack('H*').force_encoding(Encoding::UTF_8) }
    let(:bad_err) do
      begin
        @client.query(invalid_utf8)
      rescue Mysql2::Error => e
        e
      end
    end

    let(:server_info) do
      @client.server_info
    end

    before do
      # sanity check
      expect(valid_utf8.encoding).to eql(Encoding::UTF_8)
      expect(valid_utf8).to be_valid_encoding

      expect(invalid_utf8.encoding).to eql(Encoding::UTF_8)
      expect(invalid_utf8).to_not be_valid_encoding
    end

    it "returns error messages as UTF-8 by default" do
      with_internal_encoding nil do
        expect(error.message.encoding).to eql(Encoding::UTF_8)
        expect(error.message).to be_valid_encoding

        expect(bad_err.message.encoding).to eql(Encoding::UTF_8)
        expect(bad_err.message).to be_valid_encoding

        # MariaDB 10.5 returns a little different error message unlike MySQL
        # and other old MariaDBs.
        # https://jira.mariadb.org/browse/MDEV-25400
        err_str = if server_info[:version].match(/MariaDB/) && server_info[:id] >= 100500
          "??}\\001F"
        else
          "??}\u001F"
        end
        expect(bad_err.message).to include(err_str)
      end
    end

    it "returns sql state as ASCII" do
      expect(error.sql_state.encoding).to eql(Encoding::US_ASCII)
      expect(error.sql_state).to be_valid_encoding
    end

    it "returns error messages and sql state in Encoding.default_internal if set" do
      with_internal_encoding Encoding::UTF_16LE do
        expect(error.message.encoding).to eql(Encoding.default_internal)
        expect(error.message).to be_valid_encoding

        expect(bad_err.message.encoding).to eql(Encoding.default_internal)
        expect(bad_err.message).to be_valid_encoding
      end
    end
  end
end
