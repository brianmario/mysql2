# frozen_string_literal: true

require_relative 'duel_helper'

# Whole queries, as an application sends them: the options merged,
# the query sent and its result read over the worker's server's Unix
# socket, and the rows built. Small results, so mysql2's work isn't
# lost in the server's.

setup { @client = mysql_client }
teardown { @client.close }

duel 'query: SELECT 1' do
  @client.query('SELECT 1').to_a
end

duel 'query: a post by primary key' do
  @client.query('SELECT * FROM posts WHERE id = 42').to_a
end

duel 'query: 10 posts by author' do
  @client.query('SELECT * FROM posts WHERE author_id = 7 ORDER BY id LIMIT 10').to_a
end

duel 'query: 100 posts' do
  @client.query('SELECT * FROM posts WHERE id <= 100').each { |row| row }
end

duel 'query: 100 posts as arrays with symbolized keys' do
  @client.query('SELECT * FROM posts WHERE id <= 100', as: :array, symbolize_keys: true).each { |row| row }
end

duel 'query: 100 posts without caching rows' do
  @client.query('SELECT * FROM posts WHERE id <= 100', cache_rows: false).each { |row| row }
end

# Streamed, each row read from the socket as it's iterated.
duel 'query: stream 1000 posts' do
  @client.query('SELECT * FROM posts', stream: true, cache_rows: false).each { |row| row }
end

# Sets what's already there, so every iteration changes nothing.
duel 'query: UPDATE a post' do
  @client.query('UPDATE posts SET score = 52.5 WHERE id = 42')
  @client.affected_rows
end
