require 'spec_helper'

RSpec.describe 'stream ownership after an iteration callback' do
  def stream_result(sql, prepared)
    options = { stream: true, cache_rows: false }
    prepared ? @client.prepare(sql).execute(**options) : @client.query(sql, options)
  end

  [false, true].each do |prepared|
    context "with #{prepared ? 'prepared' : 'text'} results" do
      it 'permits a buffered query inside an each block' do
        result = stream_result('SELECT 1 AS n UNION ALL SELECT 2', prepared)
        values = []
        result.each { values << @client.query('SELECT 3 AS n').first['n'] }
        expect(values).to eq([3])
        expect(@client.query('SELECT 4 AS n').first['n']).to eq(4)
      end

      it 'stops cleanly when the block frees the result' do
        result = stream_result('SELECT 1 AS n UNION ALL SELECT 2', prepared)
        result.each { result.free }
        expect(@client.query('SELECT 4 AS n').first['n']).to eq(4)
      end

      [false, true].each do |explicit_free|
        it "preserves a successor stream for the next query (explicit free: #{explicit_free})" do
          first = stream_result('SELECT 1 AS n UNION ALL SELECT 2', prepared)
          first.field_types
          successor = nil
          first.each do
            first.free if explicit_free
            successor = @client.query('SELECT 3 AS n UNION ALL SELECT 4', stream: true, cache_rows: false)
          end
          expect(@client.query('SELECT 5 AS n').first['n']).to eq(5)
          expect { successor.each { |_| } }.to raise_error(Mysql2::Error, /already been freed/)
        end
      end
    end
  end
end
