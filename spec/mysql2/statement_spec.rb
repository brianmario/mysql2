require './spec/spec_helper'
require 'clocale'

RSpec.describe Mysql2::Statement do # rubocop:disable Metrics/BlockLength
  before(:example) do
    @client = new_client
  end

  let(:performance_schema_enabled) do
    performance_schema = @client.query "SHOW VARIABLES LIKE 'performance_schema'"
    performance_schema.any? { |x| x['Value'] == 'ON' }
  end

  def stmt_count
    # Use the performance schema in MySQL 5.7 and above
    if performance_schema_enabled
      @client.query("SELECT COUNT(1) AS count FROM performance_schema.prepared_statements_instances").first['count'].to_i
    else
      # Fall back to the global prepapred statement counter
      @client.query("SHOW STATUS LIKE 'Prepared_stmt_count'").first['Value'].to_i
    end
  end

  it "should create a statement" do
    statement = nil
    expect { statement = @client.prepare 'SELECT 1' }.to change(&method(:stmt_count)).by(1)
    expect(statement).to be_an_instance_of(Mysql2::Statement)
  end

  it "should raise an exception when server disconnects" do
    @client.close
    expect { @client.prepare 'SELECT 1' }.to raise_error(Mysql2::Error)
  end

  it "should tell us the param count" do
    statement = @client.prepare 'SELECT ?, ?'
    expect(statement.param_count).to eq(2)

    statement2 = @client.prepare 'SELECT 1'
    expect(statement2.param_count).to eq(0)
  end

  it "should tell us the field count" do
    statement = @client.prepare 'SELECT ?, ?'
    expect(statement.field_count).to eq(2)

    statement2 = @client.prepare 'SELECT 1'
    expect(statement2.field_count).to eq(1)
  end

  it "should let us execute our statement" do
    statement = @client.prepare 'SELECT 1'
    expect(statement.execute).not_to eq(nil)
  end

  it "should raise an exception without a block" do
    statement = @client.prepare 'SELECT 1'
    expect { statement.execute.each }.to raise_error(LocalJumpError)
  end

  it "should tell us the result count" do
    statement = @client.prepare 'SELECT 1'
    result = statement.execute
    expect(result.count).to eq(1)
  end

  it "should let us iterate over results" do
    statement = @client.prepare 'SELECT 1'
    result = statement.execute
    rows = []
    result.each { |r| rows << r }
    expect(rows).to eq([{ "1" => 1 }])
  end

  it "should report the execute round trip as the result's query_time" do
    statement = @client.prepare 'SELECT SLEEP(0.1)'
    started = clock_time
    result = statement.execute
    elapsed = clock_time - started

    expect(result.query_time).to be_a(Float)
    # SLEEP(0.1) can return a scheduler tick (~16ms on Windows) early, so the
    # bound sits below the nominal sleep -- still orders of magnitude above a
    # bracket that misses the socket wait, which measures ~0.2ms.
    expect(result.query_time).to be >= 0.05
    expect(result.query_time).to be <= elapsed
  end

  it "should report query_time before a streamed execute's rows are read" do
    statement = @client.prepare 'SELECT SLEEP(0.1)'
    result = statement.execute(stream: true, cache_rows: false)

    expect(result.query_time).to be >= 0.05
    result.each.to_a
  end

  it "should keep fields and field_types accessible for exhausted empty results" do
    statement = @client.prepare 'SELECT 1 AS only_col WHERE 1 = 0'
    result = statement.execute
    expect(result.to_a).to eql([])
    expect(result.fields).to eql(["only_col"])
    expect(result.field_types.length).to eql(1)
  end

  it "should handle booleans" do
    stmt = @client.prepare('SELECT ? AS `true`, ? AS `false`')
    result = stmt.execute(true, false)
    expect(result.to_a).to eq([{ 'true' => 1, 'false' => 0 }])
  end

  it "should handle bignum but in int64_t" do
    stmt = @client.prepare('SELECT ? AS max, ? AS min')
    int64_max = (1 << 63) - 1
    int64_min = -(1 << 63)
    result = stmt.execute(int64_max, int64_min)
    expect(result.to_a).to eq([{ 'max' => int64_max, 'min' => int64_min }])
  end

  it "should handle bignum but beyond int64_t" do
    stmt = @client.prepare('SELECT ? AS max1, ? AS max2, ? AS max3, ? AS min1, ? AS min2, ? AS min3')
    int64_max1 = (1 << 63)
    int64_max2 = (1 << 64) - 1
    int64_max3 = 1 << 64
    int64_min1 = -(1 << 63) - 1
    int64_min2 = -(1 << 64) + 1
    int64_min3 = -0xC000000000000000
    result = stmt.execute(int64_max1, int64_max2, int64_max3, int64_min1, int64_min2, int64_min3)
    expect(result.to_a).to eq([{ 'max1' => int64_max1, 'max2' => int64_max2, 'max3' => int64_max3, 'min1' => int64_min1, 'min2' => int64_min2, 'min3' => int64_min3 }])
  end

  it "should accept keyword arguments on statement execute" do
    stmt = @client.prepare 'SELECT 1 AS a'

    expect(stmt.execute(as: :hash).first).to eq("a" => 1)
    expect(stmt.execute(as: :array).first).to eq([1])
  end

  it "should accept bind arguments and keyword arguments on statement execute" do
    stmt = @client.prepare 'SELECT ? AS a'

    expect(stmt.execute(1, as: :hash).first).to eq("a" => 1)
    expect(stmt.execute(1, as: :array).first).to eq([1])
  end

  it "should yield every cell in field order for wide array rows" do
    width = 40
    stmt = @client.prepare "SELECT #{Array.new(width) { |i| "#{i} AS c#{i}" }.join(', ')}"
    expect(stmt.execute(as: :array).first).to eq((0...width).to_a)
  end

  it "should not carry array row cells over between rows" do
    stmt = @client.prepare 'SELECT 1 AS a, NULL AS b UNION SELECT NULL, 2'
    expect(stmt.execute(as: :array).to_a).to eq([[1, nil], [nil, 2]])
  end

  it "should raise TypeError naming the parameter index, class, and value for an unsupported bind type" do
    stmt = @client.prepare 'SELECT ?, ?'

    expect { stmt.execute(1, :pending) }.to \
      raise_error(TypeError, "can't bind parameter 2: no conversion for Symbol (:pending)")
    expect { stmt.execute({ key: "value" }, 2) }.to \
      raise_error(TypeError, "can't bind parameter 1: no conversion for Hash (#{{ key: 'value' }.inspect})")
    expect { stmt.execute(Object.new, 2) }.to \
      raise_error(TypeError, /\Acan't bind parameter 1: no conversion for Object \(#<Object:0x\h+>\)\z/)
  end

  it "should truncate long values in the unsupported bind type message" do
    stmt = @client.prepare 'SELECT ?'

    expect { stmt.execute(("a" * 60).to_sym) }.to \
      raise_error(TypeError, "can't bind parameter 1: no conversion for Symbol (:#{'a' * 39}...)")
  end

  it "should keep the parameter index when the value's inspect itself raises, chaining the inspect error as the cause" do
    stmt = @client.prepare 'SELECT ?, ?'
    broken = Object.new
    def broken.inspect
      raise ArgumentError, "broken inspect"
    end

    expect { stmt.execute(1, broken) }.to raise_error(TypeError, "can't bind parameter 2: no conversion for Object") { |error|
      expect(error.cause).to be_an(ArgumentError)
      expect(error.cause.message).to eq("broken inspect")
    }
  end

  it "should omit the value when its inspect contains a NUL byte" do
    stmt = @client.prepare 'SELECT ?'
    nul = Object.new
    def nul.inspect
      "nul\0byte"
    end

    expect { stmt.execute(nul) }.to \
      raise_error(TypeError, "can't bind parameter 1: no conversion for Object")
  end

  it "should remain usable after an unsupported bind type raises" do
    stmt = @client.prepare 'SELECT ? AS a'

    expect { stmt.execute(:pending) }.to raise_error(TypeError)
    expect(stmt.execute(1).first).to eq("a" => 1)
  end

  it "should raise for an unsupported bind type instead of writing zero to the table" do
    @client.query 'USE test'
    @client.query 'DROP TABLE IF EXISTS mysql2_stmt_bind_type_test'
    @client.query 'CREATE TABLE mysql2_stmt_bind_type_test (int_test INT)'

    stmt = @client.prepare("INSERT INTO mysql2_stmt_bind_type_test VALUES (?)")
    expect { stmt.execute(:pending) }.to raise_error(TypeError)
    expect(@client.query("SELECT * FROM mysql2_stmt_bind_type_test").to_a).to be_empty

    @client.query 'DROP TABLE IF EXISTS mysql2_stmt_bind_type_test'
  end

  it "should keep its result after other query" do
    @client.query 'USE test'
    @client.query 'CREATE TABLE IF NOT EXISTS mysql2_stmt_q(a int)'
    @client.query 'INSERT INTO mysql2_stmt_q (a) VALUES (1), (2)'
    stmt = @client.prepare('SELECT a FROM mysql2_stmt_q WHERE a = ?')
    result1 = stmt.execute(1)
    result2 = stmt.execute(2)
    expect(result2.first).to eq("a" => 2)
    expect(result1.first).to eq("a" => 1)
    @client.query 'DROP TABLE IF EXISTS mysql2_stmt_q'
  end

  it "should be reusable 1000 times" do
    statement = @client.prepare 'SELECT 1'
    1000.times do
      result = statement.execute
      expect(result.to_a.length).to eq(1)
    end
  end

  it "should be reusable 10000 times" do
    statement = @client.prepare 'SELECT 1'
    10000.times do
      result = statement.execute
      expect(result.to_a.length).to eq(1)
    end
  end

  it "should handle comparisons and likes" do
    @client.query 'USE test'
    @client.query 'CREATE TABLE IF NOT EXISTS mysql2_stmt_q(a int, b varchar(10))'
    @client.query 'INSERT INTO mysql2_stmt_q (a, b) VALUES (1, "Hello"), (2, "World")'
    statement = @client.prepare 'SELECT * FROM mysql2_stmt_q WHERE a < ?'
    results = statement.execute(2)
    expect(results.first).to eq("a" => 1, "b" => "Hello")

    statement = @client.prepare 'SELECT * FROM mysql2_stmt_q WHERE b LIKE ?'
    results = statement.execute('%orld')
    expect(results.first).to eq("a" => 2, "b" => "World")

    @client.query 'DROP TABLE IF EXISTS mysql2_stmt_q'
  end

  it "should select dates" do
    statement = @client.prepare 'SELECT NOW()'
    result = statement.execute
    expect(result.first.first[1]).to be_an_instance_of(Time)
  end

  it "should prepare Date values" do
    now = Date.today
    statement = @client.prepare('SELECT ? AS a')
    result = statement.execute(now)
    expect(result.first['a'].to_s).to eql(now.strftime('%F'))
  end

  it "should prepare Time values with microseconds" do
    now = Time.now
    statement = @client.prepare('SELECT ? AS a')
    result = statement.execute(now)
    # microseconds is six digits after the decimal, but only test on 5 significant figures
    expect(result.first['a'].strftime('%F %T.%5N %z')).to eql(now.strftime('%F %T.%5N %z'))
  end

  it "should prepare DateTime values with microseconds" do
    now = DateTime.now
    statement = @client.prepare('SELECT ? AS a')
    result = statement.execute(now)
    # microseconds is six digits after the decimal, but only test on 5 significant figures
    expect(result.first['a'].strftime('%F %T.%5N %z')).to eql(now.strftime('%F %T.%5N %z'))
  end

  it "should tell us about the fields" do
    statement = @client.prepare 'SELECT 1 as foo, 2'
    statement.execute
    list = statement.fields
    expect(list.length).to eq(2)
    expect(list.first).to eq('foo')
    expect(list[1]).to eq('2')
  end

  it "should handle as a decimal binding a BigDecimal" do
    stmt = @client.prepare('SELECT ? AS decimal_test')
    test_result = stmt.execute(BigDecimal("123.45")).first
    expect(test_result['decimal_test']).to be_an_instance_of(BigDecimal)
    expect(test_result['decimal_test']).to eql(123.45)
  end

  it "should update a DECIMAL value passing a BigDecimal" do
    @client.query 'USE test'
    @client.query 'DROP TABLE IF EXISTS mysql2_stmt_decimal_test'
    @client.query 'CREATE TABLE mysql2_stmt_decimal_test (decimal_test DECIMAL(10,3))'

    @client.prepare("INSERT INTO mysql2_stmt_decimal_test VALUES (?)").execute(BigDecimal("123.45"))

    test_result = @client.query("SELECT * FROM mysql2_stmt_decimal_test").first
    expect(test_result['decimal_test']).to eql(123.45)
  end

  it "should warn but still work if cache_rows is set to false" do
    statement = @client.prepare 'SELECT 1'
    result = nil
    expect { result = statement.execute(cache_rows: false).to_a }.to output(/:cache_rows is forced for prepared statements/).to_stderr
    expect(result.length).to eq(1)
  end

  it "should warn that cache_rows is forced on every #each, not only the first" do
    statement = @client.prepare 'SELECT 1'
    result = nil
    expect { result = statement.execute(cache_rows: false) }.to output(/:cache_rows is forced for prepared statements/).to_stderr
    2.times do
      expect { result.each { |_| } }.to output(/:cache_rows is forced for prepared statements/).to_stderr
    end
  end

  context "utf8_db" do
    before(:example) do
      @client.query("DROP DATABASE IF EXISTS test_mysql2_stmt_utf8")
      @client.query("CREATE DATABASE test_mysql2_stmt_utf8")
      @client.query("USE test_mysql2_stmt_utf8")
      @client.query("CREATE TABLE テーブル (整数 int, 文字列 varchar(32)) charset=utf8")
      @client.query("INSERT INTO テーブル (整数, 文字列) VALUES (1, 'イチ'), (2, '弐'), (3, 'さん')")
    end

    after(:example) do
      @client.query("DROP DATABASE test_mysql2_stmt_utf8")
    end

    it "should be able to retrieve utf8 field names correctly" do
      stmt = @client.prepare 'SELECT * FROM `テーブル`'
      expect(stmt.fields).to eq(%w[整数 文字列])
      result = stmt.execute

      expect(result.to_a).to eq([{ "整数" => 1, "文字列" => "イチ" }, { "整数" => 2, "文字列" => "弐" }, { "整数" => 3, "文字列" => "さん" }])
    end

    it "should be able to retrieve utf8 param query correctly" do
      stmt = @client.prepare 'SELECT 整数 FROM テーブル WHERE 文字列 = ?'
      expect(stmt.param_count).to eq(1)

      result = stmt.execute 'イチ'

      expect(result.to_a).to eq([{ "整数" => 1 }])
    end

    it "should be able to retrieve query with param in different encoding correctly" do
      stmt = @client.prepare 'SELECT 整数 FROM テーブル WHERE 文字列 = ?'
      expect(stmt.param_count).to eq(1)

      param = 'イチ'.encode("EUC-JP")
      result = stmt.execute param

      expect(result.to_a).to eq([{ "整数" => 1 }])
    end
  end

  context "streaming result" do
    it "should be able to stream query result" do
      n = 1
      stmt = @client.prepare("SELECT 1 UNION SELECT 2")
      stmt.execute(stream: true, cache_rows: false, as: :array).each do |r|
        case n
        when 1
          expect(r).to eq([1])
        when 2
          expect(r).to eq([2])
        else
          violated "returned more than two rows"
        end
        n += 1
      end
    end

    it "should let you execute/query again after abandoning a prepared statement's streaming result" do
      stmt = @client.prepare("SELECT 1 UNION SELECT 2 UNION SELECT 3")
      stmt.execute(stream: true, cache_rows: false).first

      expect do
        stmt.execute(stream: true, cache_rows: false)
      end.to_not raise_error

      result = @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3", stream: true, cache_rows: false)
      expect(result.to_a).to eq([{ '1' => 1 }, { '1' => 2 }, { '1' => 3 }])
    end

    it "should let a plain query drain an abandoned prepared statement streaming result" do
      stmt = @client.prepare("SELECT 1 UNION SELECT 2 UNION SELECT 3")
      stmt.execute(stream: true, cache_rows: false).first

      result = @client.query("SELECT 1 UNION SELECT 2 UNION SELECT 3")
      expect(result.to_a).to eq([{ '1' => 1 }, { '1' => 2 }, { '1' => 3 }])
    end

    it "should stream a variable-length column past its initially-bound buffer size" do
      # Regression coverage for #1058: a streaming (cursor-mode) prepared
      # statement's result buffers start too small (see the
      # MYSQL_DATA_TRUNCATED case in rb_mysql_result_fetch_row_stmt), so a
      # large column must grow its buffer mid-stream. Also covers a small
      # row fetched afterward into that already-grown buffer, which must
      # come back at its own correct length, not the buffer's.
      @client.query("DROP TABLE IF EXISTS stream_stmt_truncation_test")
      @client.query("CREATE TABLE stream_stmt_truncation_test (id INT PRIMARY KEY AUTO_INCREMENT, data MEDIUMBLOB)")

      begin
        small = "a" * 10
        large = "b" * 300_000
        ins = @client.prepare("INSERT INTO stream_stmt_truncation_test (data) VALUES (?)")
        [small, large, small].each { |v| ins.execute(v) }

        stmt = @client.prepare("SELECT data FROM stream_stmt_truncation_test ORDER BY id")
        rows = stmt.execute(stream: true, cache_rows: false).to_a
        expect(rows.map { |r| r["data"] }).to eq([small, large, small])
      ensure
        @client.query("DROP TABLE IF EXISTS stream_stmt_truncation_test")
      end
    end

    context "with stream: {size: N}" do
      # Com_stmt_fetch counts COM_STMT_FETCH commands the server received on
      # this session -- a direct observation of how many round trips a
      # cursor drain cost, from the same connection once it's idle again.
      def com_stmt_fetch_count
        @client.query("SHOW SESSION STATUS LIKE 'Com_stmt_fetch'").first['Value'].to_i
      end

      def fetches_during
        before = com_stmt_fetch_count
        yield
        com_stmt_fetch_count - before
      end

      before(:example) do
        @client.query("DROP TABLE IF EXISTS stream_prefetch_test")
        @client.query("CREATE TABLE stream_prefetch_test (id INT PRIMARY KEY AUTO_INCREMENT, v VARCHAR(32))")
        ins = @client.prepare("INSERT INTO stream_prefetch_test (v) VALUES (?)")
        20.times { |i| ins.execute("row#{i}") }
      end

      after(:example) do
        @client.query("DROP TABLE IF EXISTS stream_prefetch_test")
      end

      it "fetches N rows per round trip and returns the same rows as stream: true" do
        stmt = @client.prepare("SELECT * FROM stream_prefetch_test ORDER BY id")

        single_rows = nil
        single = fetches_during do
          single_rows = stmt.execute(stream: true, cache_rows: false).to_a
        end

        batched_rows = nil
        batched = fetches_during do
          batched_rows = stmt.execute(stream: { size: 10 }, cache_rows: false).to_a
        end

        expect(batched_rows).to eq(single_rows)
        expect(single_rows.length).to eq(20)
        expect(single).to be >= 20
        expect(batched).to be <= 4
      end

      it "resets the prefetch size when the same statement streams with stream: true again" do
        # STMT_ATTR_PREFETCH_ROWS persists on the statement handle, so a
        # plain stream: true execute after a sized one must not inherit N.
        stmt = @client.prepare("SELECT * FROM stream_prefetch_test ORDER BY id")
        stmt.execute(stream: { size: 10 }, cache_rows: false).to_a

        single = fetches_during do
          stmt.execute(stream: true, cache_rows: false).to_a
        end
        expect(single).to be >= 20
      end

      it "grows a truncated column buffer inside a multi-row batch" do
        # The regrow-on-MYSQL_DATA_TRUNCATED path (see the stream: true spec
        # above), but with the large row arriving mid-batch rather than as
        # the only row of its fetch.
        @client.query("DROP TABLE IF EXISTS stream_prefetch_grow_test")
        @client.query("CREATE TABLE stream_prefetch_grow_test (id INT PRIMARY KEY AUTO_INCREMENT, data MEDIUMBLOB)")
        begin
          small = "a" * 10
          large = "b" * 300_000
          values = [small, large, small, large, small]
          ins = @client.prepare("INSERT INTO stream_prefetch_grow_test (data) VALUES (?)")
          values.each { |v| ins.execute(v) }

          stmt = @client.prepare("SELECT data FROM stream_prefetch_grow_test ORDER BY id")
          rows = stmt.execute(stream: { size: 2 }, cache_rows: false).to_a
          expect(rows.map { |r| r["data"] }).to eq(values)
        ensure
          @client.query("DROP TABLE IF EXISTS stream_prefetch_grow_test")
        end
      end

      it "accepts stream: {size: 1} as equivalent to stream: true" do
        stmt = @client.prepare("SELECT * FROM stream_prefetch_test ORDER BY id")
        expect(stmt.execute(stream: { size: 1 }, cache_rows: false).to_a.length).to eq(20)
      end

      it "rejects invalid sizes before touching the network" do
        stmt = @client.prepare("SELECT * FROM stream_prefetch_test")
        expect { stmt.execute(stream: { size: 0 }) }.to raise_error(ArgumentError, /positive/)
        expect { stmt.execute(stream: { size: -1 }) }.to raise_error(ArgumentError, /positive/)
        expect { stmt.execute(stream: { size: 1.5 }) }.to raise_error(TypeError, /Integer/)
        expect { stmt.execute(stream: { size: "10" }) }.to raise_error(TypeError, /Integer/)
        expect { stmt.execute(stream: {}) }.to raise_error(ArgumentError, /size/)
        expect { stmt.execute(stream: { sise: 10 }) }.to raise_error(ArgumentError, /size/)
        expect { stmt.execute(stream: { size: 10, max_memory: 1 }) }.to raise_error(ArgumentError, /size/)

        # The raises above happened at option parse: the statement and
        # connection are untouched and still usable.
        expect(stmt.execute(stream: { size: 5 }, cache_rows: false).to_a.length).to eq(20)
      end
    end
  end

  context "#each" do
    # NOTE: The current impl. of prepared statement requires results to be cached on #execute except for streaming queries
    #       The drawback of this is that args of Result#each is ignored...

    it "should yield rows as hash's" do
      @result = @client.prepare("SELECT 1").execute
      @result.each do |row|
        expect(row).to be_an_instance_of(Hash)
      end
    end

    it "should return every row of a multi-row result" do
      # The result buffers are bound on the first fetch and reused for the rest
      # of the result set, so a binding that went stale would show up as wrong
      # or repeated values from the second row onward, not on the first.
      result = @client.prepare("SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4").execute
      expect(result.to_a).to eq([{ 'n' => 1 }, { 'n' => 2 }, { 'n' => 3 }, { 'n' => 4 }])
    end

    it "should return wide variable-width columns correctly on every row" do
      # Variable-width buffers start at a small fixed size and grow on
      # MYSQL_DATA_TRUNCATED (see rb_mysql_result_fetch_row_stmt). A row
      # fetched into a stale or too-short buffer would be truncated or wrong
      # here, where the value is far larger than the initial buffer.
      expected = ['a' * 60_000, 'b' * 60_000]
      result = @client.prepare("SELECT REPEAT('a', 60000) AS v UNION ALL SELECT REPEAT('b', 60000)").execute
      expect(result.to_a.map { |row| row['v'] }).to eq(expected)
    end

    it "should grow the result buffer past a wide value and keep every later row intact" do
      # A wide value truncates, grows its buffer to fit, and completes via a
      # tail-only mysql_stmt_fetch_column at the truncation offset; growing
      # can move the buffer, so the statement's registered binds are
      # re-registered before the next fetch. The varied byte patterns make a
      # misplaced tail (wrong offset, or a skipped tail fetch) show up as a
      # content mismatch, and the rows after each wide one catch a bind left
      # pointing at the buffer's pre-grow address.
      @client.query("DROP TABLE IF EXISTS stmt_buffer_grow_test")
      @client.query("CREATE TABLE stmt_buffer_grow_test (id INT PRIMARY KEY AUTO_INCREMENT, data MEDIUMBLOB)")

      begin
        pattern = ->(n) { (0...n).map { |i| ((i * 7 + 13) % 256).chr }.join.b }
        rows = [pattern.call(10), pattern.call(1_000_000), pattern.call(200), pattern.call(2_000_000), nil, pattern.call(10)]
        ins = @client.prepare("INSERT INTO stmt_buffer_grow_test (data) VALUES (?)")
        rows.each { |v| ins.execute(v) }

        stmt = @client.prepare("SELECT data FROM stmt_buffer_grow_test ORDER BY id")
        expect(stmt.execute.to_a.map { |r| r["data"] }).to eq(rows)
      ensure
        @client.query("DROP TABLE IF EXISTS stmt_buffer_grow_test")
      end
    end

    it "should grow multiple truncated columns in the same row" do
      # Each truncated column in a row is grown and tail-fetched
      # independently before the binds are re-registered once.
      @client.query("DROP TABLE IF EXISTS stmt_multi_grow_test")
      @client.query("CREATE TABLE stmt_multi_grow_test (id INT PRIMARY KEY AUTO_INCREMENT, a MEDIUMBLOB, b MEDIUMBLOB)")

      begin
        pattern = ->(n, salt) { (0...n).map { |i| ((i * 11 + salt) % 256).chr }.join.b }
        rows = [
          [pattern.call(5, 3), pattern.call(7, 5)],
          [pattern.call(70_000, 17), pattern.call(90_000, 29)],
          [pattern.call(9, 7), pattern.call(4, 11)],
        ]
        ins = @client.prepare("INSERT INTO stmt_multi_grow_test (a, b) VALUES (?, ?)")
        rows.each { |a, b| ins.execute(a, b) }

        stmt = @client.prepare("SELECT a, b FROM stmt_multi_grow_test ORDER BY id")
        expect(stmt.execute.to_a.map { |r| [r["a"], r["b"]] }).to eq(rows)
      ensure
        @client.query("DROP TABLE IF EXISTS stmt_multi_grow_test")
      end
    end

    it "should yield rows as hash's with symbol keys if :symbolize_keys was set to true" do
      @result = @client.prepare("SELECT 1").execute(symbolize_keys: true)
      @result.each do |row|
        expect(row.keys.first).to be_an_instance_of(Symbol)
      end
    end

    it "should be able to return results as an array" do
      @result = @client.prepare("SELECT 1").execute(as: :array)
      @result.each do |row|
        expect(row).to be_an_instance_of(Array)
      end
    end

    it "should cache previously yielded results by default" do
      @result = @client.prepare("SELECT 1").execute
      expect(@result.first.object_id).to eql(@result.first.object_id)
    end

    it "should yield different value for #first if streaming" do
      result = @client.prepare("SELECT 1 UNION SELECT 2").execute(stream: true, cache_rows: true)
      expect(result.first).not_to eql(result.first)
    end

    it "should yield the same value for #first if streaming is disabled" do
      result = @client.prepare("SELECT 1 UNION SELECT 2").execute(stream: false)
      expect(result.first).to eql(result.first)
    end

    it "should throw an exception if we try to iterate twice when streaming is enabled" do
      result = @client.prepare("SELECT 1 UNION SELECT 2").execute(stream: true, cache_rows: false)
      expect do
        result.to_a
        result.to_a
      end.to raise_exception(Mysql2::Error)
    end
  end

  context "#fields" do
    it "method should exist" do
      stmt = @client.prepare("SELECT 1")
      expect(stmt).to respond_to(:fields)
    end

    it "should return an array of field names in proper order" do
      stmt = @client.prepare("SELECT 'a', 'b', 'c'")
      expect(stmt.fields).to eql(%w[a b c])
    end

    it "should return nil for statement with no result fields" do
      stmt = @client.prepare("INSERT INTO mysql2_test () VALUES ()")
      expect(stmt.fields).to eql(nil)
    end

    context "on results iterated in array mode" do
      # Array rows never contain field names, so names are batch-materialized
      # on the first fetched row instead of fetched per cell. These pin that
      # Result#fields behaves exactly as it did with the per-cell
      # materialization over the binary protocol, including after an abandoned
      # stream is force-freed by the next query.
      let(:sql) { "SELECT 1 AS a, 10 AS b UNION SELECT 2, 20 UNION SELECT 3, 30" }

      it "should return field names after iteration" do
        result = @client.prepare(sql).execute(as: :array)
        result.to_a
        expect(result.fields).to eql(%w[a b])
      end

      it "should honor symbolize_keys in fields" do
        result = @client.prepare(sql).execute(as: :array, symbolize_keys: true)
        result.to_a
        expect(result.fields).to eql(%i[a b])
      end

      it "should keep fields accessible for exhausted empty results" do
        result = @client.prepare("SELECT 1 AS a WHERE 1 = 0").execute(as: :array)
        expect(result.to_a).to eql([])
        expect(result.fields).to eql(["a"])
      end

      it "should keep fields accessible after an abandoned stream is force-freed by the next query" do
        # The next query force-frees the abandoned stream without the
        # natural-completion metadata caching, so the names materialized by
        # the first fetched row are the only copy left.
        result = @client.prepare(sql).execute(as: :array, stream: true, cache_rows: false)
        result.each { |_| break } # rubocop:disable Lint/UnreachableLoop
        @client.query("SELECT 1")
        expect(result.fields).to eql(%w[a b])
      end

      it "should keep raising for a never-iterated stream force-freed by the next query" do
        # No row was ever fetched, so no names were materialized to survive
        # the force-free.
        result = @client.prepare(sql).execute(as: :array, stream: true, cache_rows: false)
        @client.query("SELECT 1")
        expect { result.fields }.to raise_error(Mysql2::Error, "Result set has already been freed")
      end

      it "should honor symbolize_keys in fields after a force-freed abandoned stream" do
        result = @client.prepare(sql).execute(as: :array, symbolize_keys: true, stream: true, cache_rows: false)
        result.each { |_| break } # rubocop:disable Lint/UnreachableLoop
        @client.query("SELECT 1")
        expect(result.fields).to eql(%i[a b])
      end

      it "should keep fields accessible for exhausted empty streaming results" do
        result = @client.prepare("SELECT 1 AS a WHERE 1 = 0").execute(as: :array, stream: true, cache_rows: false)
        expect(result.each.to_a).to eql([])
        expect(result.fields).to eql(["a"])
      end
    end
  end

  context "metadata cached across executes" do
    # A statement caches its metadata-derived artifacts (field-name array,
    # result bind buffers) between executes, re-reading and validating the
    # metadata each time. These specs pin the seams: buffers sized by a
    # previous execute's data, metadata invalidated by ALTER TABLE, per-execute
    # option changes, mutation isolation of #fields, and GC/compaction safety
    # of the VALUEs rooted on the statement wrapper.
    before(:example) do
      @client.query "CREATE TEMPORARY TABLE cross_execute_test (id INT, val VARCHAR(255))"
      @client.query "INSERT INTO cross_execute_test (id, val) VALUES (1, 'short')"
    end

    it "should return fresh rows on every execute, growing value buffers as the data widens" do
      stmt = @client.prepare "SELECT id, val FROM cross_execute_test ORDER BY id"
      expect(stmt.execute.to_a).to eql([{ "id" => 1, "val" => "short" }])

      @client.query "INSERT INTO cross_execute_test (id, val) VALUES (2, REPEAT('x', 255))"
      expect(stmt.execute.to_a).to eql([{ "id" => 1, "val" => "short" }, { "id" => 2, "val" => "x" * 255 }])
    end

    it "should reread metadata when ALTER TABLE changes a column type between executes" do
      @client.query "CREATE TEMPORARY TABLE alter_type_test (id INT, num INT)"
      @client.query "INSERT INTO alter_type_test VALUES (1, 42)"
      stmt = @client.prepare "SELECT * FROM alter_type_test"
      expect(stmt.execute.first["num"]).to eql(42)

      @client.query "ALTER TABLE alter_type_test MODIFY num VARCHAR(16)"
      expect(stmt.execute.first["num"]).to eql("42")
    end

    it "should reread metadata when ALTER TABLE flips a column to unsigned between executes" do
      @client.query "CREATE TEMPORARY TABLE alter_unsigned_test (num INT)"
      @client.query "INSERT INTO alter_unsigned_test VALUES (1)"
      stmt = @client.prepare "SELECT * FROM alter_unsigned_test"
      expect(stmt.execute.first["num"]).to eql(1)

      @client.query "ALTER TABLE alter_unsigned_test MODIFY num INT UNSIGNED"
      @client.query "UPDATE alter_unsigned_test SET num = 4294967295"
      expect(stmt.execute.first["num"]).to eql(4294967295)
    end

    it "should keep row keys in step with the statement's own fresh metadata after ALTER TABLE renames a column" do
      # MySQL pins a prepared handle's result-set column names for the life of
      # the handle (even Statement#fields, which re-reads metadata, reports the
      # original name after a rename), so this cannot demand the new name.
      # What it pins instead is that cached names always track whatever the
      # freshly read metadata reports: on a server that does propagate the
      # rename, stale cached names would break this equality.
      @client.query "CREATE TEMPORARY TABLE alter_name_test (id INT, before_name INT)"
      @client.query "INSERT INTO alter_name_test VALUES (1, 42)"
      stmt = @client.prepare "SELECT * FROM alter_name_test"
      expect(stmt.execute.first.keys).to eql(stmt.fields)

      @client.query "ALTER TABLE alter_name_test CHANGE before_name after_name INT"
      expect(stmt.execute.first.keys).to eql(stmt.fields)
    end

    it "should re-elect bind types when the cast mode changes between executes" do
      # Bind types are elected from the cast mode (cast: true binds server
      # types; cast: false / :fast bind strings), so cached buffers carry
      # their election across executes and an execute under the other mode
      # must re-elect rather than decode through the adopted types.
      stmt = @client.prepare "SELECT id, val FROM cross_execute_test"
      expect(stmt.execute(cast: false).first).to eql("id" => "1", "val" => "short")
      expect(stmt.execute.first).to eql("id" => 1, "val" => "short")
      expect(stmt.execute(cast: :fast).first).to eql("id" => 1, "val" => "short")
    end

    it "should not reuse field names for an execute with different :symbolize_keys" do
      stmt = @client.prepare "SELECT id FROM cross_execute_test"
      expect(stmt.execute(symbolize_keys: true).first.keys).to eql([:id])
      expect(stmt.execute.first.keys).to eql(["id"])
      expect(stmt.execute(symbolize_keys: true).first.keys).to eql([:id])
    end

    it "should give each execute's result its own #fields array" do
      stmt = @client.prepare "SELECT id, val FROM cross_execute_test"
      # The first result's array is the one the statement harvests; the
      # second's is handed out from the cache. Mutating both proves neither
      # end of the exchange shares an array with the statement.
      first = stmt.execute
      first.fields << "mutated on harvest side"
      second = stmt.execute
      expect(second.fields).to eql(%w[id val])
      second.fields << "mutated on adoption side"
      expect(stmt.execute.fields).to eql(%w[id val])
    end

    it "should keep results correct across GC and compaction with a held statement" do
      stmt = @client.prepare "SELECT id, val FROM cross_execute_test ORDER BY id"
      expected = stmt.execute.to_a
      stmt.execute
      GC.start
      GC.verify_compaction_references(expand_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references) && RUBY_VERSION >= "3.2"
      result = stmt.execute
      expect(result.to_a).to eql(expected)
      expect(result.fields).to eql(%w[id val])
    end

    it "should keep results correct when GC.stress runs between executes" do
      stmt = @client.prepare "SELECT id, val FROM cross_execute_test"
      expected = stmt.execute.to_a
      begin
        GC.stress = true
        3.times { expect(stmt.execute.to_a).to eql(expected) }
      ensure
        GC.stress = false
      end
    end
  end

  context "row data type mapping" do
    let(:test_result) { @client.prepare("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").execute.first }

    it "should return nil for a NULL value" do
      expect(test_result['null_test']).to be_an_instance_of(NilClass)
      expect(test_result['null_test']).to eql(nil)
    end

    it "should return String for a BIT(64) value" do
      expect(test_result['bit_test']).to be_an_instance_of(String)
      expect(test_result['bit_test']).to eql("\000\000\000\000\000\000\000\005")
    end

    it "should return String for a BIT(1) value" do
      expect(test_result['single_bit_test']).to be_an_instance_of(String)
      expect(test_result['single_bit_test']).to eql("\001")
    end

    it "should return Fixnum for a TINYINT value" do
      expect(num_classes).to include(test_result['tiny_int_test'].class)
      expect(test_result['tiny_int_test']).to eql(1)
    end

    context "cast booleans for TINYINT if :cast_booleans is enabled" do
      # rubocop:disable Style/Semicolon
      let(:id1) { @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES ( 1)'; @client.last_id }
      let(:id2) { @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES ( 0)'; @client.last_id }
      let(:id3) { @client.query 'INSERT INTO mysql2_test (bool_cast_test) VALUES (-1)'; @client.last_id }
      # rubocop:enable Style/Semicolon

      after do
        @client.query "DELETE from mysql2_test WHERE id IN(#{id1},#{id2},#{id3})"
      end

      it "should return TrueClass or FalseClass for a TINYINT value if :cast_booleans is enabled" do
        query = @client.prepare 'SELECT bool_cast_test FROM mysql2_test WHERE id = ?'
        result1 = query.execute id1, cast_booleans: true
        result2 = query.execute id2, cast_booleans: true
        result3 = query.execute id3, cast_booleans: true
        expect(result1.first['bool_cast_test']).to be true
        expect(result2.first['bool_cast_test']).to be false
        expect(result3.first['bool_cast_test']).to be true
      end
    end

    context "cast booleans for BIT(1) if :cast_booleans is enabled" do
      # rubocop:disable Style/Semicolon
      let(:id1) { @client.query 'INSERT INTO mysql2_test (single_bit_test) VALUES (1)'; @client.last_id }
      let(:id2) { @client.query 'INSERT INTO mysql2_test (single_bit_test) VALUES (0)'; @client.last_id }
      # rubocop:enable Style/Semicolon

      after do
        @client.query "DELETE from mysql2_test WHERE id IN(#{id1},#{id2})"
      end

      it "should return TrueClass or FalseClass for a BIT(1) value if :cast_booleans is enabled" do
        query = @client.prepare 'SELECT single_bit_test FROM mysql2_test WHERE id = ?'
        result1 = query.execute id1, cast_booleans: true
        result2 = query.execute id2, cast_booleans: true
        expect(result1.first['single_bit_test']).to be true
        expect(result2.first['single_bit_test']).to be false
      end
    end

    it "should return Fixnum for a SMALLINT value" do
      expect(num_classes).to include(test_result['small_int_test'].class)
      expect(test_result['small_int_test']).to eql(10)
    end

    it "should return Fixnum for a MEDIUMINT value" do
      expect(num_classes).to include(test_result['medium_int_test'].class)
      expect(test_result['medium_int_test']).to eql(10)
    end

    it "should return Fixnum for an INT value" do
      expect(num_classes).to include(test_result['int_test'].class)
      expect(test_result['int_test']).to eql(10)
    end

    it "should return Fixnum for a BIGINT value" do
      expect(num_classes).to include(test_result['big_int_test'].class)
      expect(test_result['big_int_test']).to eql(10)
    end

    it "should return Fixnum for a YEAR value" do
      expect(num_classes).to include(test_result['year_test'].class)
      expect(test_result['year_test']).to eql(2009)
    end

    it "should return BigDecimal for a DECIMAL value" do
      expect(test_result['decimal_test']).to be_an_instance_of(BigDecimal)
      expect(test_result['decimal_test']).to eql(10.3)
    end

    it "should return Float for a FLOAT value" do
      expect(test_result['float_test']).to be_an_instance_of(Float)
      expect(test_result['float_test']).to eql(10.3)
    end

    it "returns the same Float for a FLOAT value via a prepared statement as via a plain query" do
      # A FLOAT column's value should read the same regardless of protocol
      # (#1276): FLT_DIG significant digits with no explicit precision,
      # or FLOAT(M,D)'s declared decimal places otherwise.
      @client.query "DROP TABLE IF EXISTS mysql2_float_parity_test"
      @client.query "CREATE TABLE mysql2_float_parity_test (a FLOAT, b FLOAT(255,30))"
      @client.query "INSERT INTO mysql2_float_parity_test VALUES (#{1.0 / 3}, 1e38)"

      plain = @client.query("SELECT a, b FROM mysql2_float_parity_test").first
      prepared = @client.prepare("SELECT a, b FROM mysql2_float_parity_test").execute.first

      expect(prepared).to eql(plain)
      @client.query "DROP TABLE mysql2_float_parity_test"
    end

    context "under a locale that uses a comma as the decimal separator" do
      before(:example) do
        @original_locale = CLocale.setlocale(CLocale::LC_NUMERIC, nil)
        begin
          CLocale.setlocale(CLocale::LC_NUMERIC, "de_DE.UTF-8")
        rescue RuntimeError
          skip "de_DE.UTF-8 locale not installed on this system"
        end
      end

      after(:example) do
        CLocale.setlocale(CLocale::LC_NUMERIC, @original_locale) if @original_locale
      end

      it "should return the correct Float for a FLOAT value" do
        result = @client.prepare("SELECT CAST(2.7 AS FLOAT) AS val").execute
        expect(result.first['val']).to eql(2.7)
      end
    end

    it "should return Float for a DOUBLE value" do
      expect(test_result['double_test']).to be_an_instance_of(Float)
      expect(test_result['double_test']).to eql(10.3)
    end

    it "should return Time for a DATETIME value when within the supported range" do
      expect(test_result['date_time_test']).to be_an_instance_of(Time)
      expect(test_result['date_time_test'].strftime("%Y-%m-%d %H:%M:%S")).to eql('2010-04-04 11:44:00')
    end

    it "should return Time when timestamp is < 1901-12-13 20:45:52" do
      r = @client.prepare("SELECT CAST('1901-12-13 20:45:51' AS DATETIME) as test").execute
      expect(r.first['test']).to be_an_instance_of(Time)
    end

    it "should return Time when timestamp is > 2038-01-19T03:14:07" do
      r = @client.prepare("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test").execute
      expect(r.first['test']).to be_an_instance_of(Time)
    end

    it "should return Time for a TIMESTAMP value when within the supported range" do
      expect(test_result['timestamp_test']).to be_an_instance_of(Time)
      expect(test_result['timestamp_test'].strftime("%Y-%m-%d %H:%M:%S")).to eql('2010-04-04 11:44:00')
    end

    it "should return Time for a TIME value" do
      expect(test_result['time_test']).to be_an_instance_of(Time)
      expect(test_result['time_test'].strftime("%Y-%m-%d %H:%M:%S")).to eql('2000-01-01 11:44:00')
    end

    context "a TIME value outside a single day (#719)" do
      # Binary-protocol TIME decoding used to ignore MYSQL_TIME.neg entirely,
      # so a negative TIME silently came back with the wrong sign (positive
      # instead of negative) rather than nil/raising like the text protocol.
      before(:context) do
        new_client do |client|
          client.query("DROP TABLE IF EXISTS mysql2_time_duration_stmt_test")
          client.query("CREATE TABLE mysql2_time_duration_stmt_test (t TIME(6))")
          %w[24:00:00 24:00:01 -01:00:00 838:59:59 -838:59:59 12:34:56.25].each do |t|
            client.query("INSERT INTO mysql2_time_duration_stmt_test VALUES ('#{t}')")
          end
        end
      end

      after(:context) do
        new_client { |client| client.query("DROP TABLE IF EXISTS mysql2_time_duration_stmt_test") }
      end

      it "returns the same duration-anchored Time via a prepared statement as via a plain query" do
        text = @client.query("SELECT t FROM mysql2_time_duration_stmt_test ORDER BY t").map { |r| r['t'] }
        stmt = @client.prepare("SELECT t FROM mysql2_time_duration_stmt_test ORDER BY t").execute.map { |r| r['t'] }
        expect(stmt).to eql(text)
      end
    end

    it "should return Date for a DATE value" do
      expect(test_result['date_test']).to be_an_instance_of(Date)
      expect(test_result['date_test'].strftime("%Y-%m-%d")).to eql('2010-04-04')
    end

    it "should return String for an ENUM value" do
      expect(test_result['enum_test']).to be_an_instance_of(String)
      expect(test_result['enum_test']).to eql('val1')
    end

    context "zero and partial-zero dates" do
      before do
        @client.query("SET SESSION sql_mode = ''")
        @client.query("DROP TABLE IF EXISTS mysql2_zero_dates")
        @client.query("CREATE TABLE mysql2_zero_dates (d DATE, dt DATETIME, ts_test TIMESTAMP NULL)")
        @client.query("INSERT INTO mysql2_zero_dates VALUES ('0000-00-00', '0000-00-00 00:00:00', '0000-00-00 00:00:00')")
      end

      after do
        @client.query("DROP TABLE IF EXISTS mysql2_zero_dates")
      end

      it "returns nil for zero dates over the binary protocol, matching the text protocol" do
        text_row = @client.query("SELECT * FROM mysql2_zero_dates").first
        stmt_row = @client.prepare("SELECT * FROM mysql2_zero_dates").execute.first
        expect(text_row).to eql("d" => nil, "dt" => nil, "ts_test" => nil)
        expect(stmt_row).to eql(text_row)
      end

      it "raises Mysql2::Error for partial-zero DATETIME values over both protocols" do
        @client.query("UPDATE mysql2_zero_dates SET dt = '1972-00-27 00:00:00'")
        expect { @client.query("SELECT dt FROM mysql2_zero_dates").to_a }.to \
          raise_error(Mysql2::Error, /Invalid date in field 'dt': 1972-00-27 00:00:00/)
        expect { @client.prepare("SELECT dt FROM mysql2_zero_dates").execute.to_a }.to \
          raise_error(Mysql2::Error, /Invalid date in field 'dt': 1972-00-27 00:00:00/)
        # The binary path reports the same (aliased) field name the text path does.
        expect { @client.prepare("SELECT dt AS aliased_dt FROM mysql2_zero_dates").execute.to_a }.to \
          raise_error(Mysql2::Error, /Invalid date in field 'aliased_dt'/)
      end

      it "raises Mysql2::Error for partial-zero DATE values over both protocols" do
        @client.query("UPDATE mysql2_zero_dates SET d = '1972-00-27'")
        expect { @client.query("SELECT d FROM mysql2_zero_dates").to_a }.to \
          raise_error(Mysql2::Error, /Invalid date in field 'd': 1972-00-27/)
        expect { @client.prepare("SELECT d FROM mysql2_zero_dates").execute.to_a }.to \
          raise_error(Mysql2::Error, /Invalid date in field 'd': 1972-00-27/)
      end

      it "keeps both protocols identical for invalid-but-storable dates under ALLOW_INVALID_DATES" do
        @client.query("SET SESSION sql_mode = 'ALLOW_INVALID_DATES'")
        @client.query("UPDATE mysql2_zero_dates SET d = '2004-04-31', dt = '2004-04-31 12:00:00'")
        # DATE: Date.new rejects the invalid civil date on both paths. Matched
        # as ArgumentError/"invalid date" rather than Date::Error, which is
        # Ruby 3.0+ only; it subclasses ArgumentError and carries the same
        # message, so this is exact on 3.x and still correct on 2.6.
        expect { @client.query("SELECT d FROM mysql2_zero_dates").to_a }.to \
          raise_error(ArgumentError, /invalid date/)
        expect { @client.prepare("SELECT d FROM mysql2_zero_dates").execute.to_a }.to \
          raise_error(ArgumentError, /invalid date/)
        # DATETIME: Time normalizes the overflow identically on both paths.
        text_val = @client.query("SELECT dt FROM mysql2_zero_dates").first["dt"]
        stmt_val = @client.prepare("SELECT dt FROM mysql2_zero_dates").execute.first["dt"]
        expect(stmt_val).to eql(text_val)
      end
    end

    it "should raise an error given an invalid DATETIME" do
      server_info = @client.server_info
      if server_info[:version].include?('MariaDB') || server_info[:id] < 80000
        expect { @client.query("SELECT CAST('1972-00-27 00:00:00' AS DATETIME) as bad_datetime").each }.to \
          raise_error(Mysql2::Error, "Invalid date in field 'bad_datetime': 1972-00-27 00:00:00")
      else
        expect(@client.query("SELECT CAST('1972-00-27 00:00:00' AS DATETIME) as bad_datetime").to_a.first).to \
          eql("bad_datetime" => nil)
      end
    end

    context "string encoding for ENUM values" do
      it "should default to the connection's encoding if Encoding.default_internal is nil" do
        with_internal_encoding nil do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['enum_test'].encoding).to eql(Encoding::UTF_8)

          client2 = new_client(encoding: 'ascii')
          result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['enum_test'].encoding).to eql(Encoding::US_ASCII)
        end
      end

      it "should use Encoding.default_internal" do
        with_internal_encoding Encoding::UTF_8 do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['enum_test'].encoding).to eql(Encoding.default_internal)
        end

        with_internal_encoding Encoding::ASCII do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['enum_test'].encoding).to eql(Encoding.default_internal)
        end
      end
    end

    it "should return String for a SET value" do
      expect(test_result['set_test']).to be_an_instance_of(String)
      expect(test_result['set_test']).to eql('val1,val2')
    end

    context "string encoding for SET values" do
      it "should default to the connection's encoding if Encoding.default_internal is nil" do
        with_internal_encoding nil do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['set_test'].encoding).to eql(Encoding::UTF_8)

          client2 = new_client(encoding: 'ascii')
          result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['set_test'].encoding).to eql(Encoding::US_ASCII)
        end
      end

      it "should use Encoding.default_internal" do
        with_internal_encoding Encoding::UTF_8 do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['set_test'].encoding).to eql(Encoding.default_internal)
        end

        with_internal_encoding Encoding::ASCII do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['set_test'].encoding).to eql(Encoding.default_internal)
        end
      end
    end

    it "should return String for a BINARY value" do
      expect(test_result['binary_test']).to be_an_instance_of(String)
      expect(test_result['binary_test']).to eql("test#{"\000" * 6}")
    end

    context "string encoding for BINARY values" do
      it "should default to binary if Encoding.default_internal is nil" do
        with_internal_encoding nil do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['binary_test'].encoding).to eql(Encoding::BINARY)
        end
      end

      it "should not use Encoding.default_internal" do
        with_internal_encoding Encoding::UTF_8 do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['binary_test'].encoding).to eql(Encoding::BINARY)
        end

        with_internal_encoding Encoding::ASCII do
          result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
          expect(result['binary_test'].encoding).to eql(Encoding::BINARY)
        end
      end
    end

    {
      'char_test'        => 'CHAR',
      'varchar_test'     => 'VARCHAR',
      'varbinary_test'   => 'VARBINARY',
      'tiny_blob_test'   => 'TINYBLOB',
      'tiny_text_test'   => 'TINYTEXT',
      'blob_test'        => 'BLOB',
      'text_test'        => 'TEXT',
      'medium_blob_test' => 'MEDIUMBLOB',
      'medium_text_test' => 'MEDIUMTEXT',
      'long_blob_test'   => 'LONGBLOB',
      'long_text_test'   => 'LONGTEXT',
    }.each do |field, type|
      it "should return a String for #{type}" do
        expect(test_result[field]).to be_an_instance_of(String)
        expect(test_result[field]).to eql("test")
      end

      context "string encoding for #{type} values" do
        if %w[VARBINARY TINYBLOB BLOB MEDIUMBLOB LONGBLOB].include?(type)
          it "should default to binary if Encoding.default_internal is nil" do
            with_internal_encoding nil do
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              expect(result['binary_test'].encoding).to eql(Encoding::BINARY)
            end
          end

          it "should not use Encoding.default_internal" do
            with_internal_encoding Encoding::UTF_8 do
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              expect(result['binary_test'].encoding).to eql(Encoding::BINARY)
            end

            with_internal_encoding Encoding::ASCII do
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              expect(result['binary_test'].encoding).to eql(Encoding::BINARY)
            end
          end
        else
          it "should default to utf-8 if Encoding.default_internal is nil" do
            with_internal_encoding nil do
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              expect(result[field].encoding).to eql(Encoding::UTF_8)

              client2 = new_client(encoding: 'ascii')
              result = client2.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              expect(result[field].encoding).to eql(Encoding::US_ASCII)
            end
          end

          it "should use Encoding.default_internal" do
            with_internal_encoding Encoding::UTF_8 do
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              expect(result[field].encoding).to eql(Encoding.default_internal)
            end

            with_internal_encoding Encoding::ASCII do
              result = @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first
              expect(result[field].encoding).to eql(Encoding.default_internal)
            end
          end
        end
      end
    end
  end

  context "with the :force_encoding execute option" do
    # 0x68C3A96C6C6F is "héllo" in UTF-8.
    let(:sql) { "SELECT _utf8mb4 0x68C3A96C6C6F AS utf8_val, UNHEX('DEADBEEF') AS binary_val" }

    it "retags string values with the forced encoding, bytes unchanged" do
      row = @client.prepare(sql).execute(force_encoding: 'ISO-8859-1').first
      expect(row['utf8_val'].encoding).to eql(Encoding::ISO_8859_1)
      expect(row['utf8_val'].bytes).to eql("h\xC3\xA9llo".bytes)
    end

    it "accepts an Encoding object and retags BLOB/binary values too" do
      row = @client.prepare(sql).execute(force_encoding: Encoding::UTF_8).first
      expect(row['binary_val'].encoding).to eql(Encoding::UTF_8)
      expect(row['binary_val'].bytes).to eql([0xDE, 0xAD, 0xBE, 0xEF])
    end

    it "combines with bind parameters and leaves NULL and non-string values alone" do
      row = @client.prepare("SELECT ? AS str_val, NULL AS null_val, 1 AS int_val").execute("abc", force_encoding: 'binary').first
      expect(row['str_val'].encoding).to eql(Encoding::BINARY)
      expect(row['null_val']).to be_nil
      expect(row['int_val']).to eql(1)
    end

    it "retags string values through streaming execution" do
      rows = @client.prepare("SELECT 'ab' UNION SELECT 'cd'").execute(stream: true, cache_rows: false, as: :array, force_encoding: 'binary').to_a
      expect(rows).to eql([['ab'], ['cd']])
      expect(rows.flatten.map(&:encoding).uniq).to eql([Encoding::BINARY])
    end

    it "raises for an unknown encoding name before the statement executes" do
      @client.query("CREATE TEMPORARY TABLE mysql2_stmt_force_encoding_probe (id INT)")
      stmt = @client.prepare("INSERT INTO mysql2_stmt_force_encoding_probe VALUES (1)")
      expect { stmt.execute(force_encoding: 'not-an-encoding') }
        .to raise_error(ArgumentError, /unknown encoding name.*not-an-encoding/)
      # Nothing hit the wire: the INSERT never ran, and both the connection
      # and the statement are still usable.
      expect(@client.query("SELECT COUNT(*) AS n FROM mysql2_stmt_force_encoding_probe").first['n']).to eql(0)
      stmt.execute
      expect(@client.query("SELECT COUNT(*) AS n FROM mysql2_stmt_force_encoding_probe").first['n']).to eql(1)
    end
  end

  context 'last_id' do
    before(:example) do
      @client.query 'USE test'
      @client.query 'CREATE TABLE IF NOT EXISTS lastIdTest (`id` BIGINT NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))'
    end

    after(:example) do
      @client.query 'DROP TABLE lastIdTest'
    end

    it 'should return last insert id' do
      stmt = @client.prepare 'INSERT INTO lastIdTest (blah) VALUES (?)'
      expect(stmt.last_id).to eq 0
      stmt.execute 1
      expect(stmt.last_id).to eq 1
    end

    it 'should handle bigint ids' do
      stmt = @client.prepare 'INSERT INTO lastIdTest (id, blah) VALUES (?, ?)'
      stmt.execute 5000000000, 5000
      expect(stmt.last_id).to eql(5000000000)

      stmt = @client.prepare 'INSERT INTO lastIdTest (blah) VALUES (?)'
      stmt.execute 5001
      expect(stmt.last_id).to eql(5000000001)
    end
  end

  context 'server_flags' do
    it "reflects the result's own execute, not later commands on the connection" do
      full_scan = @client.prepare('SELECT * FROM mysql2_test').execute
      # Move the connection's live status on to a query that touches no table
      # before reading the first result's flags.
      no_scan = @client.prepare('SELECT 1').execute

      expect(full_scan.server_flags).to eql(no_good_index_used: false, no_index_used: true, query_was_slow: false)
      expect(no_scan.server_flags[:no_index_used]).to eql(false)
    end
  end

  context 'affected_rows' do
    before(:example) do
      @client.query 'USE test'
      @client.query 'CREATE TABLE IF NOT EXISTS lastIdTest (`id` BIGINT NOT NULL AUTO_INCREMENT, blah INT(11), PRIMARY KEY (`id`))'
    end

    after(:example) do
      @client.query 'DROP TABLE lastIdTest'
    end

    it 'should return number of rows affected by an insert' do
      stmt = @client.prepare 'INSERT INTO lastIdTest (blah) VALUES (?)'
      stmt.execute 1
      expect(stmt.affected_rows).to eq 1
    end

    it 'should return number of rows affected by an update' do
      stmt = @client.prepare 'INSERT INTO lastIdTest (blah) VALUES (?)'
      stmt.execute 1
      expect(stmt.affected_rows).to eq 1
      stmt.execute 2
      expect(stmt.affected_rows).to eq 1

      stmt = @client.prepare 'UPDATE lastIdTest SET blah=? WHERE blah=?'
      stmt.execute 0, 1
      expect(stmt.affected_rows).to eq 1
    end

    it 'should return number of rows affected by a delete' do
      stmt = @client.prepare 'INSERT INTO lastIdTest (blah) VALUES (?)'
      stmt.execute 1
      expect(stmt.affected_rows).to eq 1
      stmt.execute 2
      expect(stmt.affected_rows).to eq 1

      stmt = @client.prepare 'DELETE FROM lastIdTest WHERE blah=?'
      stmt.execute 1
      expect(stmt.affected_rows).to eq 1
    end
  end

  context 'close' do
    it 'should free server resources' do
      stmt = @client.prepare 'SELECT 1'
      GC.disable
      expect { stmt.close }.to change(&method(:stmt_count)).by(-1)
      GC.enable
    end

    it 'should raise an error on subsequent execution' do
      stmt = @client.prepare 'SELECT 1'
      stmt.close
      expect { stmt.execute }.to raise_error(Mysql2::Error, /Invalid statement handle/)
    end

    it 'should not raise if called multiple times' do
      stmt = @client.prepare 'SELECT 1'
      expect(stmt).to_not be_closed

      3.times do
        expect { stmt.close }.to_not raise_error
        expect(stmt).to be_closed
      end
    end
  end

  context 'garbage collection ordering' do
    # Regression coverage for the deferred pending-close queue (see
    # decr_mysql2_stmt / mysql2_reap_pending_stmt_closes in
    # ext/mysql2/{client,statement}.c). Before that fix, a Statement's GC
    # free function sent COM_STMT_CLOSE straight onto the wire even while
    # the connection was mid protocol exchange for something else,
    # corrupting whatever command was actually in flight and producing
    # "commands out of sync" (#1043) or wrong results.

    it 'does not corrupt results when a stale prepared statement is collected between executes' do
      begin
        GC.stress = true
        50.times do |i|
          want = i.odd? ? 1 : nil
          found = nil
          @client.prepare('SELECT 1 AS FOUND WHERE 1 = ?').execute(i.odd? ? 1 : 0).each do |row|
            found = row['FOUND']
          end
          expect(found).to eq(want)
        end
      ensure
        GC.stress = false
      end
    end

    it 'does not corrupt a streaming read when a stale statement on the same client is collected mid-stream' do
      # Not held onto past this point, so it becomes GC-eligible once
      # nothing else references it.
      stale = @client.prepare('SELECT 1')
      stale.execute.each { |_| }
      stale = nil # rubocop:disable Lint/UselessAssignment

      result = @client.query('SELECT 1 AS a UNION SELECT 2 AS a UNION SELECT 3 AS a', stream: true)
      rows = []
      begin
        GC.stress = true
        result.each { |row| rows << row['a'] }
      ensure
        GC.stress = false
      end
      expect(rows).to eq([1, 2, 3])
    end

    it 'drains #pending_prepared_statement_closes to zero at the next safe point' do
      30.times { @client.prepare('SELECT 1').execute }
      GC.start
      @client.ping
      expect(@client.pending_prepared_statement_closes).to eq(0)
    end
  end
end
