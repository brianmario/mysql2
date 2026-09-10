require 'spec_helper'

RSpec.describe 'cached prepared results after statement close' do
  %i[hash array].each do |shape|
    it "replays fully materialized #{shape} rows after closing the statement" do
      statement = @client.prepare('SELECT 1 AS n UNION ALL SELECT 2 ORDER BY n')
      result = statement.execute(as: shape)
      statement.close
      expected = shape == :array ? [[1], [2]] : [{ 'n' => 1 }, { 'n' => 2 }]
      expect(result.to_a).to eq(expected)
      expect(result.to_a).to eq(expected)
      expect(result.first).to eq(expected.first)
      expect(result.fields).to eq(['n'])
      # Integer types and display widths differ between servers; an integer
      # family name is enough to show the cached metadata survived close.
      expect(result.field_types.first).to match(/int/)
      expect(result.size).to eq(2)
      expect(@client.query('SELECT 3 AS n').first['n']).to eq(3)
    end
  end

  it 'replays an empty materialized result after closing the statement' do
    statement = @client.prepare('SELECT 1 AS n WHERE 0')
    result = statement.execute
    statement.close
    expect(result.to_a).to eq([])
    expect(result.to_a).to eq([])
    expect(result.size).to eq(0)
    expect(result.fields).to eq(['n'])
  end

  %w[unread half-read completed].each do |state|
    it "still rejects a #{state} prepared stream after closing the statement" do
      statement = @client.prepare('SELECT 1 AS n UNION ALL SELECT 2 ORDER BY n')
      result = statement.execute(stream: true, cache_rows: false)
      case state
      when 'half-read' then expect(result.first).to eq('n' => 1)
      when 'completed' then expect(result.to_a).to eq([{ 'n' => 1 }, { 'n' => 2 }])
      end
      statement.close
      expect { result.to_a }.to raise_error(Mysql2::Error, /Statement handle already closed/)
      expect(@client.query('SELECT 3 AS n').first['n']).to eq(3)
    end
  end
end
