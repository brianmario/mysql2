# encoding: UTF-8
require 'spec_helper'

# The matrix of error encoding tests:
# ('Enc = X' means 'Encoding.default_internal = X')
#                  MySQL < 5.5   MySQL >= 5.5
# Ruby 1.8         N/A           N/A
# Ruby 1.9+
#  Enc = nil
#  :enc = nil      BINARY        UTF-8
#
#  Enc = XYZ
#  :enc = XYZ      BINARY        XYZ
#
#  Enc = FOO
#  :enc = BAR      BINARY        FOO
#


describe Mysql2::Error do
  shared_examples "mysql2 error" do
    begin
      err_client = Mysql2::Client.new(DatabaseCredentials['root'])
      err_client.query("HAHAHA")
    rescue Mysql2::Error => e
      error = e
    ensure
      err_client.close
    end

    subject { error }
    it { should respond_to(:error_number) }
    it { should respond_to(:sql_state) }

    # Mysql gem compatibility
    it { should respond_to(:errno) }
    it { should respond_to(:error) }
  end

  shared_examples "mysql2 error encoding" do |db_enc, def_enc, err_enc|
    Encoding.default_internal = def_enc

    begin
      err_client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => db_enc))
      err_client.query("造字")
    rescue Mysql2::Error => e
      error = e
    ensure
      err_client.close
    end

    subject { error.message.encoding }
    it { should eql(err_enc) }

    subject { error.error.encoding }
    it { should eql(err_enc) }

    subject { error.sql_state.encoding }
    it { should eql(err_enc) }
  end

  it_behaves_like "mysql2 error"

  unless RUBY_VERSION =~ /1.8/
    mysql_ver = Mysql2::Client.new(DatabaseCredentials['root']).server_info[:id]
    if mysql_ver < 50505
      it_behaves_like "mysql2 error encoding", nil, nil, Encoding::ASCII_8BIT
      it_behaves_like "mysql2 error encoding", 'utf8', Encoding::UTF_8, Encoding::ASCII_8BIT
      it_behaves_like "mysql2 error encoding", 'big5', Encoding::Big5, Encoding::ASCII_8BIT
      it_behaves_like "mysql2 error encoding", 'big5', Encoding::US_ASCII, Encoding::ASCII_8BIT
    else
      it_behaves_like "mysql2 error encoding", nil, nil, Encoding::UTF_8
      it_behaves_like "mysql2 error encoding", 'utf8', Encoding::UTF_8, Encoding::UTF_8
      it_behaves_like "mysql2 error encoding", 'big5', Encoding::Big5, Encoding::Big5
      it_behaves_like "mysql2 error encoding", 'big5', Encoding::US_ASCII, Encoding::US_ASCII
    end
  end
end
