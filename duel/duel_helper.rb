# frozen_string_literal: true

require 'bigdecimal'
require 'date'

# Each worker has a MySQL server of its own (see .duel.rb), listening on
# a Unix socket, with the tables in duel/schema.sql.
def mysql_client(options = {})
  Mysql2::Client.new({ socket: Duel::MySQL.socket, username: 'root', database: 'duel' }.merge(options))
end

# A buffered result of the query, with cache_rows: false, so every #each
# builds each row again from what the client library already read: no
# round trip to the server, only mysql2's own work turning rows into
# Ruby objects.
def buffered_result(client, sql, options = {})
  client.query(sql, options.merge(cache_rows: false))
end
