require 'spec_helper'

RSpec.describe 'server error message encoding' do
  [nil, Encoding::UTF_8].each do |internal|
    it "decodes latin1 query errors with default_internal #{internal.inspect}" do
      client = new_client(encoding: 'latin1')
      with_internal_encoding(internal) do
        expect { client.query("SELECT missing_é".encode('ISO-8859-1')) }.to raise_error(Mysql2::Error) { |error|
          expect(error.message.valid_encoding?).to eq(true)
          expect(error.message.encoding).to eq(internal || Encoding::ISO_8859_1)
          expect(error.message.encode('UTF-8')).to include('missing_é')
          expect(error.error_number).to eq(1054)
          expect(error.sql_state).to eq('42S22')
        }
      end
      expect(client.query('SELECT 3 AS n').first['n']).to eq(3)
    end
  end

  it 'keeps client-library errors UTF-8 regardless of the connection charset' do
    socket = '/nonexistent/mysql2_missing_é.sock'
    expect { Mysql2::Client.new(socket: socket, host: nil, encoding: 'latin1') }.to raise_error(Mysql2::Error::ConnectionError) { |error|
      expect(error.error_number).to be_between(2000, 2999)
      expect(error.message.valid_encoding?).to eq(true)
      expect(error.message.encoding).to eq(Encoding::UTF_8)
      expect(error.message).to include('mysql2_missing_é')
    }
  end

  it 'preserves UTF-8 errors on a UTF-8 connection' do
    expect { @client.query('SELECT missing_é') }.to raise_error(Mysql2::Error) { |error|
      expect(error.message.valid_encoding?).to eq(true)
      expect(error.message).to include('missing_é')
    }
  end
end
