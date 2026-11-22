# frozen_string_literal: true

require_relative 'duel_helper'

# Turning rows into Ruby objects, which ext/mysql2/result.c does for
# every row of every query. Each benchmark queries once, untimed, and
# then iterates the buffered result (see buffered_result), so what's
# timed is mysql2's own work and never the server's.

setup { @client = mysql_client }
teardown { @client.close }

posts = 'SELECT * FROM posts WHERE id <= 100'

duel 'result: 100 posts as hashes' do
  once { @result = buffered_result(@client, posts) }
  @result.each { |row| row }
end

duel 'result: 100 posts as arrays' do
  once { @result = buffered_result(@client, posts, as: :array) }
  @result.each { |row| row }
end

duel 'result: 100 posts with symbolized keys' do
  once { @result = buffered_result(@client, posts, symbolize_keys: true) }
  @result.each { |row| row }
end

duel 'result: 100 posts with cast_booleans' do
  once { @result = buffered_result(@client, posts, cast_booleans: true) }
  @result.each { |row| row }
end

duel 'result: 100 posts without casting' do
  once { @result = buffered_result(@client, posts, cast: false) }
  @result.each { |row| row }
end

duel 'result: 100 posts with cast: :fast' do
  once { @result = buffered_result(@client, posts, cast: :fast) }
  @result.each { |row| row }
end

duel 'result: 100 posts with to_a' do
  once { @result = buffered_result(@client, posts) }
  @result.to_a
end

duel 'result: 1000 posts as arrays' do
  once { @result = buffered_result(@client, 'SELECT * FROM posts', as: :array) }
  @result.each { |row| row }
end

# With cache_rows (the default), the first #each keeps the rows, and the
# next ones yield what it kept.
duel 'result: 100 cached posts again' do
  once do
    @result = @client.query(posts)
    @result.each { |row| row }
  end
  @result.each { |row| row }
end

# Casting, a few columns of a type at a time, from 100 rows of the
# typed table.
{
  'integers'          => 'tiny_int, small_int, medium_int, int_value, big_int',
  'floats'            => 'float_value, double_value',
  'decimals'          => 'price, ratio, balance, quantity',
  'dates'             => 'birthday, starts_on, ends_on',
  'datetimes'         => 'happened_at, recorded_at, stamped_at',
  'times'             => 'opens_at, lasted',
  'JSON documents'    => 'document',
  'strings and blobs' => 'name, note, payload',
}.each do |type, columns|
  duel "result: cast 100 rows of #{type}" do
    once { @result = buffered_result(@client, "SELECT #{columns} FROM typed", as: :array) }
    @result.each { |row| row }
  end
end

datetimes = 'SELECT happened_at, recorded_at, stamped_at FROM typed'

duel 'result: cast 100 rows of datetimes stored in UTC' do
  once { @result = buffered_result(@client, datetimes, as: :array, database_timezone: :utc) }
  @result.each { |row| row }
end

duel 'result: cast 100 rows of datetimes from UTC to local' do
  once { @result = buffered_result(@client, datetimes, as: :array, database_timezone: :utc, application_timezone: :local) }
  @result.each { |row| row }
end
