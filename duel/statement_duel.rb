# frozen_string_literal: true

require_relative 'duel_helper'

# Prepared statements: binding parameters to MySQL's buffers, and
# building rows from the binary protocol (rb_mysql_result_fetch_row_stmt
# in ext/mysql2/result.c), which every Statement#execute materializes.

setup { @client = mysql_client }
teardown { @client.close }

duel 'statement: a post by primary key' do
  once { @statement = @client.prepare('SELECT * FROM posts WHERE id = ?') }
  @statement.execute(42).to_a
end

duel 'statement: 7 parameters of mixed types' do
  once do
    @statement = @client.prepare('SELECT id FROM posts WHERE id = ? AND author_id = ? AND title <> ? AND score > ? ' \
                                 'AND published = ? AND created_at > ? AND updated_at > ?')
    @params = [42, 42, 'Untitled café', 1.5, true, Time.local(2025, 12, 31, 12, 30, 15, 250_000), Date.new(2025, 12, 31)]
  end
  @statement.execute(*@params).to_a
end

duel 'statement: 100 posts' do
  once { @statement = @client.prepare('SELECT * FROM posts WHERE id <= ?') }
  @statement.execute(100).each { |row| row }
end

duel 'statement: 100 posts as arrays' do
  once { @statement = @client.prepare('SELECT * FROM posts WHERE id <= ?') }
  @statement.execute(100, as: :array).each { |row| row }
end

duel 'statement: 100 rows of dates, times and decimals' do
  once do
    @statement = @client.prepare('SELECT price, balance, birthday, happened_at, recorded_at, opens_at FROM typed WHERE id <= ?')
  end
  @statement.execute(100, as: :array).each { |row| row }
end

duel 'statement: prepare and close' do
  @client.prepare('SELECT * FROM posts WHERE id = ?').close
end
