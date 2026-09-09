require 'spec_helper'
require 'weakref'

RSpec.describe 'prepared statement collection' do
  it 'collects discarded statements and closes their server handles at the next safe command' do
    before = @client.query("SHOW SESSION STATUS LIKE 'Com_stmt_close'").first['Value'].to_i
    new_thread do
      12.times { @client.prepare('SELECT 1 AS n').execute }
      nil
    end.join
    GC.start
    expect(@client.prepared_statements).to eq([])
    @client.ping
    expect(@client.pending_prepared_statement_closes).to eq(0)
    after = @client.query("SHOW SESSION STATUS LIKE 'Com_stmt_close'").first['Value'].to_i
    expect(after - before).to eq(12)
  end

  it 'preserves application-owned statements through collection and compaction' do
    statement = @client.prepare('SELECT 7 AS n')
    GC.start
    GC.verify_compaction_references(expand_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references) && RUBY_VERSION >= '3.2'
    expect(@client.prepared_statements).to eq([statement])
    expect(statement.execute.first).to eq('n' => 7)
    statement.close
    expect(@client.prepared_statements).to eq([])
  end

  it 'keeps a statement alive while its result is still referenced' do
    result, reference = new_thread do
      statement = @client.prepare('SELECT 8 AS n')
      [statement.execute, WeakRef.new(statement)]
    end.value
    GC.start
    expect(reference.weakref_alive?).to be_truthy
    expect(result.to_a).to eq([{ 'n' => 8 }])
    expect(@client.prepared_statements).to eq([reference.__getobj__])
  end

  it 'does not flush collected handles when inspected during an async query' do
    ready = Queue.new
    release = Queue.new
    worker = new_thread do
      statements = Array.new(5) { @client.prepare('SELECT 1') }
      ready << statements.length
      release.pop
      statements.clear
      nil
    end
    expect(ready.pop).to eq(5)
    @client.query('SELECT SLEEP(0.05) AS n', async: true)
    release << true
    worker.join
    GC.start
    pending = @client.pending_prepared_statement_closes
    expect(pending).to be > 0
    expect(@client.prepared_statements).to eq([])
    expect(@client.pending_prepared_statement_closes).to eq(pending)
    expect(@client.async_result.first).to eq('n' => 0)
    expect(@client.query('SELECT 3 AS n').first['n']).to eq(3)
  end
end
