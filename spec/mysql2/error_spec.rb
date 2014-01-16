# encoding: UTF-8
require 'spec_helper'

# The matrix of error encoding tests:
# Ruby 1.8
#  N/A
#
# Ruby 1.9+
#  Encoding.default_internal | Database conn encoding | Error text encoding
#  nil                       | nil                    | UTF-8
#  X                         | X                      | X
#  X                         | Y                      | X
#
# The output text is default_internal if set, or UTF-8 otherwise.

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

  shared_examples "mysql2 error encoding" do |db_enc, def_enc, err_enc, match_re|
    Encoding.default_internal = def_enc

    begin
      err_client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => db_enc))
      err_client.query("\u9020\u5B57") # Simplified Chinese: "user-defined characters"
    rescue Mysql2::Error => e
      error = e
    ensure
      err_client.close
    end

    it "#message   should match the expected text or replacement chars" do error.message.force_encoding("ASCII-8BIT").should match(match_re) end

    subject { error.message.encoding }
    it "#message   should transcode from #{db_enc.inspect} to #{err_enc}" do should eql(err_enc) end

    subject { error.error.encoding }
    it "#error     should transcode from #{db_enc.inspect} to #{err_enc}" do should eql(err_enc) end

    subject { error.sql_state.encoding }
    it "#sql_state should transcode from #{db_enc.inspect} to #{err_enc}" do should eql(err_enc) end
  end

  it_behaves_like "mysql2 error"

  unless RUBY_VERSION =~ /1.8/
    # Sadly, I had to do the regexes entirely in binary.
    # The first two are equivalent to the unicode above.
    # The third is MySQL's Big5 conversion of the above.
    # The fourth is but a simple US-ASCII question mark.
    it_behaves_like "mysql2 error encoding", nil   , nil               , Encoding::UTF_8   , %r/near '\xE9\x80\xA0\xE5\xAD\x97'/n
    it_behaves_like "mysql2 error encoding", 'utf8', Encoding::UTF_8   , Encoding::UTF_8   , %r/near '\xE9\x80\xA0\xE5\xAD\x97'/n
    it_behaves_like "mysql2 error encoding", 'big5', Encoding::Big5    , Encoding::Big5    , %r/near '\xB3\x79\xA6\x72'/n
    # FIXME it_behaves_like "mysql2 error encoding", 'latin1', Encoding::ISO_8859_1, Encoding::ISO_8859_1, %r/near '\?\?'/n
    it_behaves_like "mysql2 error encoding", 'big5', Encoding::US_ASCII, Encoding::US_ASCII, %r/near '\?\?'/n
  end
end
