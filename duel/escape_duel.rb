# frozen_string_literal: true

require_relative 'duel_helper'

# Escaping a string for an SQL literal, which an application (or Active
# Record's quoting) does for every string it puts in a query.

setup { @client = mysql_client }
teardown { @client.close }

duel 'escape: a string with nothing to escape' do
  @client.escape('jane.doe@example.com')
end

duel 'escape: a string with quotes and a backslash' do
  @client.escape(%q(O'Reilly's "Ruby" C:\\Ruby))
end

duel 'escape: a 4 KB string with quotes' do
  once { @text = (%q(It's a "quoted" line, with a backslash \\ and café. ) * 80).byteslice(0, 4096).scrub }
  @client.escape(@text)
end

duel 'escape: Mysql2::Client.escape' do
  Mysql2::Client.escape(%q(O'Reilly's "Ruby" C:\\Ruby))
end
