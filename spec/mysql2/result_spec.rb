require 'spec_helper'
require 'clocale'

RSpec.describe Mysql2::Result do # rubocop:disable Metrics/BlockLength
  before(:example) do
    @result = @client.query "SELECT 1"
  end

  it "should raise a TypeError exception when it doesn't wrap a result set" do
    expect { Mysql2::Result.new }.to raise_error(TypeError)
    expect { Mysql2::Result.allocate }.to raise_error(TypeError)
  end

  it "should have included Enumerable" do
    expect(Mysql2::Result.ancestors.include?(Enumerable)).to be true
  end

  it "should respond to #each" do
    expect(@result).to respond_to(:each)
  end

  it "should respond to #free" do
    expect(@result).to respond_to(:free)
  end

  it "should raise when iterating a result freed before being fully cached" do
    result = @client.query "SELECT 1"
    result.free
    expect { result.each.to_a }.to raise_error(Mysql2::Error, "Result set has already been freed")
  end

  it "should raise when iterating a freed cache_rows: false result instead of replaying nil rows" do
    result = @client.query "SELECT 1 AS a UNION SELECT 2", cache_rows: false
    result.each { |_| }
    result.free
    expect { result.to_a }.to raise_error(Mysql2::Error, "Result set has already been freed")
  end

  it "should raise when iterating a streaming result freed before completion" do
    result = @client.query "SELECT 1 AS a UNION SELECT 2", stream: true, cache_rows: false
    result.free
    expect { result.each { |_| } }.to raise_error(Mysql2::Error, "Result set has already been freed")
  end

  it "should stop iterating cleanly when the result is freed inside the block" do
    result = @client.query "SELECT 1 AS a UNION SELECT 2 UNION SELECT 3"
    seen = []
    result.each do |row|
      seen << row
      result.free
    end
    expect(seen).to eql([{ "a" => 1 }])
  end

  it "should still replay cached rows after the result is freed" do
    result = @client.query "SELECT 1 AS a UNION SELECT 2"
    rows = result.to_a # fully cached; C result auto-freed here
    result.free
    expect(result.to_a).to eql(rows)
  end

  it "should tolerate free inside the block for materialized prepared-statement results" do
    # Non-streaming statement results are fully materialized (and their C
    # result freed) during #execute, so iteration replays the cache and an
    # in-block free is a harmless no-op.
    result = @client.prepare("SELECT 1 AS a UNION SELECT 2 UNION SELECT 3").execute
    seen = []
    result.each do |row|
      seen << row
      result.free
    end
    expect(seen).to eql([{ "a" => 1 }, { "a" => 2 }, { "a" => 3 }])
  end

  it "should stop a streaming prepared-statement iteration cleanly when freed inside the block" do
    result = @client.prepare("SELECT 1 AS a UNION SELECT 2 UNION SELECT 3").execute(stream: true, cache_rows: false)
    seen = []
    result.each do |row|
      seen << row
      result.free
    end
    expect(seen).to eql([{ "a" => 1 }])
  end

  it "should keep the streaming-specific error for re-iterating a completed stream" do
    result = @client.query "SELECT 1 AS a UNION SELECT 2", stream: true
    result.each { |_| }
    expect { result.each { |_| } }.to raise_error(Mysql2::Error, /streaming is true.*to reiterate you must requery/)
  end

  it "should keep field_types valid across GC and compaction" do
    result = @client.query "SELECT 1 AS a, 'x' AS b"
    before_types = result.field_types.dup
    GC.start
    GC.verify_compaction_references(expand_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references) && RUBY_VERSION >= "3.2"
    expect(result.field_types).to eql(before_types)
  end

  it "should keep field_types valid when GC runs during the first call" do
    # The array is stored on the C struct before the fill loop runs, and that
    # loop allocates a String per column, so a GC inside it can collect the
    # still-unmarked array between the store and the rb_ary_store that follows.
    # That window is a write into a freed slot, and it is inside the very first
    # #field_types call -- the spec above only covers a stale read on a later
    # one. Ordinary GC is enough here; compaction is not part of the mechanism.
    # Reproduction from @jeremy (#1453). Three fresh results give three
    # independent first-call windows: whether the dying array temporary is
    # conservatively pinned on the C stack is compiler/layout luck, so one
    # window could theoretically survive unpatched where another aborts.
    3.times do
      result = @client.query "SELECT 1 AS a, 'x' AS b, 2.5 AS c, NOW() AS d"
      begin
        GC.stress = true
        types = result.field_types # first-ever call on this Result
      ensure
        GC.stress = false
      end
      expect(types).to be_an_instance_of(Array)
      expect(types.length).to eql(4)
      expect(types).to all(be_an_instance_of(String))
    end
  end

  it "should raise a Mysql2::Error exception upon a bad query" do
    expect do
      @client.query "bad sql"
    end.to raise_error(Mysql2::Error)

    expect do
      @client.query "SELECT 1"
    end.not_to raise_error
  end

  it "should respond to #count, which is aliased as #size" do
    r = @client.query "SELECT 1"
    expect(r).to respond_to :count
    expect(r).to respond_to :size
  end

  it "should be able to return the number of rows in the result set" do
    r = @client.query "SELECT 1"
    expect(r.count).to eql(1)
    expect(r.size).to eql(1)
    expect(r.empty?).to eq(false)
  end

  context "metadata queries" do
    it "should show tables" do
      @result = @client.query "SHOW TABLES"
    end
  end

  context "#empty?" do
    it "should return true when result is not exists" do
      r = @client.query "SELECT * FROM mysql2_test WHERE 0 = 1"
      expect(r).to be_empty
    end

    it "should return false when result exists" do
      r = @client.query "SELECT 1"
      expect(r).not_to be_empty
    end
  end

  context "#each" do
    it "should return the same rows for any :rows_per_gvl_yield" do
      # The option only changes how often rb_thread_schedule is called while
      # materializing buffered rows, so every value must produce identical rows.
      # How often other threads actually get scheduled is timing-dependent and
      # deliberately not asserted here.
      baseline = @client.query("SELECT 1 AS a UNION ALL SELECT 2 UNION ALL SELECT 3").to_a
      [0, 1, 2, 8192].each do |n|
        rows = @client.query("SELECT 1 AS a UNION ALL SELECT 2 UNION ALL SELECT 3",
                             rows_per_gvl_yield: n,).to_a
        expect(rows).to eql(baseline), ":rows_per_gvl_yield => #{n} changed the rows"
      end
    end

    it "should reject a negative :rows_per_gvl_yield" do
      expect { @client.query("SELECT 1", rows_per_gvl_yield: -1).to_a }.to \
        raise_error(Mysql2::Error, /rows_per_gvl_yield/)
    end

    it "should yield rows as hash's" do
      @result.each do |row|
        expect(row).to be_an_instance_of(Hash)
      end
    end

    it "should yield rows as hash's with symbol keys if :symbolize_keys was set to true" do
      @result.each(symbolize_keys: true) do |row|
        expect(row.keys.first).to be_an_instance_of(Symbol)
      end
    end

    it "should be able to return results as an array" do
      @result.each(as: :array) do |row|
        expect(row).to be_an_instance_of(Array)
      end
    end

    it "should cache previously yielded results by default" do
      expect(@result.first.object_id).to eql(@result.first.object_id)
    end

    it "should not cache previously yielded results if cache_rows is disabled" do
      result = @client.query "SELECT 1", cache_rows: false
      expect(result.first.object_id).not_to eql(result.first.object_id)
    end

    it "should be able to iterate a second time even if cache_rows is disabled" do
      result = @client.query "SELECT 1 UNION SELECT 2", cache_rows: false
      expect(result.to_a).to eql(result.to_a)
    end

    it "should yield different value for #first if streaming" do
      result = @client.query "SELECT 1 UNION SELECT 2", stream: true, cache_rows: false
      expect(result.first).not_to eql(result.first)
    end

    it "should yield the same value for #first if streaming is disabled" do
      result = @client.query "SELECT 1 UNION SELECT 2", stream: false
      expect(result.first).to eql(result.first)
    end

    it "should throw an exception if we try to iterate twice when streaming is enabled" do
      result = @client.query "SELECT 1 UNION SELECT 2", stream: true, cache_rows: false

      expect do
        result.each.to_a
        result.each.to_a
      end.to raise_exception(Mysql2::Error)
    end
  end

  context "#fields" do
    let(:test_result) { @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1") }

    it "method should exist" do
      expect(test_result).to respond_to(:fields)
    end

    it "should return an array of field names in proper order" do
      result = @client.query "SELECT 'a', 'b', 'c'"
      expect(result.fields).to eql(%w[a b c])
    end

    it "should return an array of frozen strings" do
      result = @client.query "SELECT 'a', 'b', 'c'"
      result.fields.each do |f|
        expect(f).to be_frozen
      end
    end

    it "should keep fields and field_types accessible for exhausted empty results" do
      result = @client.query("SELECT 1 AS only_col WHERE 1 = 0")
      expect(result.each.to_a).to eql([])
      expect(result.fields).to eql(["only_col"])
      expect(result.field_types.length).to eql(1)
    end

    it "should keep fields and field_types accessible for exhausted empty streaming results" do
      result = @client.query("SELECT 1 AS only_col WHERE 1 = 0", stream: true, cache_rows: false)
      expect(result.each.to_a).to eql([])
      expect(result.fields).to eql(["only_col"])
      expect(result.field_types.length).to eql(1)
    end

    it "should keep fields and field_types accessible after free" do
      result = @client.query("SELECT 1 AS only_col WHERE 1 = 0")
      result.free
      expect(result.fields).to eql(["only_col"])
      expect(result.field_types.length).to eql(1)
    end
  end

  context "#field_types" do
    let(:test_result) { @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1") }

    it "method should exist" do
      expect(test_result).to respond_to(:field_types)
    end

    it "should return correct types" do
      expected_types = %w[
        mediumint(9)
        varchar(13)
        bit(64)
        bit(1)
        tinyint(4)
        tinyint(1)
        smallint(6)
        mediumint(9)
        int(11)
        bigint(20)
        float(10,3)
        float(10,3)
        double(10,3)
        decimal(10,3)
        decimal(10,3)
        date
        datetime
        timestamp
        time
        year(4)
        char(13)
        varchar(13)
        binary(10)
        varbinary(10)
        tinyblob
        text(1020)
        blob
        text(262140)
        mediumblob
        text(67108860)
        longblob
        longtext
        enum
        set
      ]

      expect(test_result.field_types).to eql(expected_types)
    end

    it "should return an array of field types in proper order" do
      result = @client.query(
        "SELECT cast('a' as char), " \
        "cast(1.2 as decimal(15, 2)), " \
        "cast(1.2 as decimal(15, 5)), " \
        "cast(1.2 as decimal(15, 4)), " \
        "cast(1.2 as decimal(15, 10)), " \
        "cast(1.2 as decimal(14, 0)), " \
        "cast(1.2 as decimal(15, 0)), " \
        "cast(1.2 as decimal(16, 0)), " \
        "cast(1.0 as decimal(16, 1))",
      )

      expected_types = %w[
        varchar(1)
        decimal(15,2)
        decimal(15,5)
        decimal(15,4)
        decimal(15,10)
        decimal(14,0)
        decimal(15,0)
        decimal(16,0)
        decimal(16,1)
      ]

      expect(result.field_types).to eql(expected_types)
    end

    it "should return json type" do
      result = @client.query("SELECT JSON_OBJECT('key', 'value')")
      expect(result.field_types).to eql(['json'])
    end
  end

  context "streaming" do
    it "should maintain a count while streaming" do
      result = @client.query('SELECT 1', stream: true, cache_rows: false)
      expect(result.count).to eql(0)
      result.each.to_a
      expect(result.count).to eql(1)
    end

    it "should retain the count when mixing first and each" do
      result = @client.query("SELECT 1 UNION SELECT 2", stream: true, cache_rows: false)
      expect(result.count).to eql(0)
      result.first
      expect(result.count).to eql(1)
      result.each.to_a
      expect(result.count).to eql(2)
    end

    it "should not yield nil at the end of streaming" do
      result = @client.query('SELECT * FROM mysql2_test', stream: true, cache_rows: false)
      result.each { |r| expect(r).not_to be_nil }
    end

    it "#count should be zero for rows after streaming when there were no results" do
      @client.query "USE test"
      result = @client.query("SELECT * FROM mysql2_test WHERE null_test IS NOT NULL", stream: true, cache_rows: false)
      expect(result.count).to eql(0)
      result.each.to_a
      expect(result.count).to eql(0)
    end

    it "should raise an exception if streaming ended due to a timeout" do
      # A Unix socket is used deliberately: a TCP loopback connection's much
      # larger write buffer means the server may never actually block on the
      # write, so net_write_timeout below would never trigger.
      client = new_socket_client
      client.query "CREATE TEMPORARY TABLE streamingTest (val BINARY(255)) ENGINE=MEMORY"

      # Insert enough records to force the result set into multiple reads
      # (the BINARY type is used simply because it forces full width results)
      10000.times do |i|
        client.query "INSERT INTO streamingTest (val) VALUES ('Foo #{i}')"
      end

      client.query "SET net_write_timeout = 1"
      res = client.query "SELECT * FROM streamingTest", stream: true, cache_rows: false

      expect do
        res.each_with_index do |_, i|
          # Exhaust the first result packet then trigger a timeout
          sleep 4 if i > 0 && i % 1000 == 0
        end
      end.to raise_error(Mysql2::Error, /Lost connection/)
    end

    it "streaming ended due to a timeout over TLS may or may not raise an exception" do
      client = new_client(ssl_mode: 'required')
      client.query "CREATE TEMPORARY TABLE streamingTest (val BINARY(255)) ENGINE=MEMORY"

      # Insert enough records to force the result set into multiple reads
      # (the BINARY type is used simply because it forces full width results)
      10000.times do |i|
        client.query "INSERT INTO streamingTest (val) VALUES ('Foo #{i}')"
      end

      client.query "SET net_write_timeout = 1"
      res = client.query "SELECT * FROM streamingTest", stream: true, cache_rows: false

      # Whether net_write_timeout's forced disconnect surfaces within this
      # window appears to depend on the platform/OpenSSL build (observed:
      # fires on macOS's stack, doesn't reproduce here on Linux's, even
      # though both are equally using TLS) -- accept either outcome here
      # rather than assert a specific one. When it does fire, OpenSSL may
      # intercept the abrupt close as a record-layer EOF before the MySQL
      # protocol layer gets a chance to raise its own "Lost connection" --
      # both are the same underlying event, just observed at a different
      # layer, so accept either message too.
      begin
        res.each_with_index do |_, i|
          sleep 4 if i > 0 && i % 1000 == 0
        end
      rescue Mysql2::Error => e
        expect(e.message).to match(%r{Lost connection|TLS/SSL error})
      end
    end
  end

  context "row data type mapping" do
    let(:test_result) { @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1").first }

    it "should return nil values for NULL and strings for everything else when :cast is false" do
      result = @client.query('SELECT null_test, tiny_int_test, bool_cast_test, int_test, date_test, enum_test FROM mysql2_test WHERE bool_cast_test = 1 LIMIT 1', cast: false).first
      expect(result["null_test"]).to be_nil
      expect(result["tiny_int_test"]).to eql("1")
      expect(result["bool_cast_test"]).to eql("1")
      expect(result["int_test"]).to eql("10")
      expect(result["date_test"]).to eql("2010-04-04")
      expect(result["enum_test"]).to eql("val1")
    end

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
        result1 = @client.query "SELECT bool_cast_test FROM mysql2_test WHERE id = #{id1} LIMIT 1", cast_booleans: true
        result2 = @client.query "SELECT bool_cast_test FROM mysql2_test WHERE id = #{id2} LIMIT 1", cast_booleans: true
        result3 = @client.query "SELECT bool_cast_test FROM mysql2_test WHERE id = #{id3} LIMIT 1", cast_booleans: true
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
        result1 = @client.query "SELECT single_bit_test FROM mysql2_test WHERE id = #{id1}", cast_booleans: true
        result2 = @client.query "SELECT single_bit_test FROM mysql2_test WHERE id = #{id2}", cast_booleans: true
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

    it "should return Float for a DOUBLE value" do
      expect(test_result['double_test']).to be_an_instance_of(Float)
      expect(test_result['double_test']).to eql(10.3)
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

      it "should return the correct BigDecimal for a DECIMAL value between -1 and 1" do
        result = @client.query("SELECT CAST(0.5 AS DECIMAL(10,2)) AS val")
        expect(result.first['val']).to eql(BigDecimal("0.5"))
      end

      it "should return the correct BigDecimal for a zero DECIMAL value" do
        result = @client.query("SELECT CAST(0.00 AS DECIMAL(10,2)) AS val")
        expect(result.first['val']).to eql(BigDecimal("0.0"))
      end

      it "should return the correct Float for a FLOAT value" do
        result = @client.query("SELECT CAST(2.7 AS FLOAT) AS val")
        expect(result.first['val']).to eql(2.7)
      end

      it "should return the correct Float for a DOUBLE value" do
        result = @client.query("SELECT CAST(2.7 AS DOUBLE) AS val")
        expect(result.first['val']).to eql(2.7)
      end
    end

    it "should return Time for a DATETIME value when within the supported range" do
      expect(test_result['date_time_test']).to be_an_instance_of(Time)
      expect(test_result['date_time_test'].strftime("%Y-%m-%d %H:%M:%S")).to eql('2010-04-04 11:44:00')
    end

    it "should return Time when timestamp is < 1901-12-13 20:45:52" do
      r = @client.query("SELECT CAST('1901-12-13 20:45:51' AS DATETIME) as test")
      expect(r.first['test']).to be_an_instance_of(Time)
    end

    it "should return Time when timestamp is > 2038-01-19T03:14:07" do
      r = @client.query("SELECT CAST('2038-01-19 03:14:08' AS DATETIME) as test")
      expect(r.first['test']).to be_an_instance_of(Time)
    end

    it "should return Time for a TIMESTAMP value when within the supported range" do
      expect(test_result['timestamp_test']).to be_an_instance_of(Time)
      expect(test_result['timestamp_test'].strftime("%Y-%m-%d %H:%M:%S")).to eql('2010-04-04 11:44:00')
    end

    it "should parse DATETIME values identically to the sscanf path across fractional widths" do
      # Each literal is cast to the DATETIME(N) that actually puts N fractional
      # digits on the wire. Casting everything to DATETIME(6) would not do:
      # the server normalises '...56.5' to '...56.500000', so the short forms
      # would never reach the parser at all. The cast: false read pins that
      # premise, so if the server ever stopped emitting these widths the test
      # fails rather than quietly stopping testing them.
      # Microseconds are left-aligned: ".5" is 500000, not 5.
      [
        ['2026-07-28 12:34:56',        'DATETIME',    0],
        ['2026-07-28 12:34:56.5',      'DATETIME(1)', 500_000],
        ['2026-07-28 12:34:56.05',     'DATETIME(2)', 50_000],
        ['2026-07-28 12:34:56.123',    'DATETIME(3)', 123_000],
        ['2026-07-28 12:34:56.000001', 'DATETIME(6)', 1],
        ['2026-07-28 12:34:56.123456', 'DATETIME(6)', 123_456],
        ['1000-01-01 00:00:00.999999', 'DATETIME(6)', 999_999],
      ].each do |literal, type, usec|
        sql = "SELECT CAST('#{literal}' AS #{type}) AS t"

        raw = @client.query(sql, cast: false).first['t']
        expect(raw).to eql(literal), "#{type}: parser was handed #{raw.inspect}, not #{literal.inspect}"

        row = @client.query(sql, database_timezone: :utc).first['t']
        expect(row).to be_an_instance_of(Time)
        expect(row.usec).to eql(usec), "#{literal}: expected usec #{usec}, got #{row.usec}"
        expect(row.strftime('%Y-%m-%d %H:%M:%S')).to eql(literal[0, 19])
        expect(row.utc_offset).to eql(0)
      end
    end

    it "should return nil for a zero DATETIME, as the sscanf path did" do
      # A zero date is canonical in shape, so it is accepted by the fast parser
      # rather than handed to the fallback. It must still come back as nil.
      expect(@client.query("SELECT CAST('0000-00-00 00:00:00' AS DATETIME) AS t").first['t']).to be_nil
    end

    it "should build :utc DATETIME values identically to the generic Time path" do
      # Pins the arithmetic fast path against Time.utc across the range and
      # precision edges, including both sides of the 32-bit time_t boundary:
      # 2038-01-19 03:14:07 is the last representable second there, 03:14:08
      # the first one past it, which on a 32-bit build must decline to the
      # funcall rather than wrap.
      [
        ['1901-12-13 20:45:51.000000', 0],
        ['1969-12-31 23:59:59.123456', 123_456],
        ['1970-01-01 00:00:00.000001', 1],
        ['2038-01-19 03:14:07.000000', 0],
        ['2038-01-19 03:14:08.000000', 0],
        ['2026-07-28 12:34:56.654321', 654_321],
        ['9999-12-31 11:59:59.500000', 500_000],
      ].each do |literal, usec|
        date_part, time_part = literal.split(' ')
        y, mo, d = date_part.split('-').map(&:to_i)
        h, mi, s = time_part.split(':')
        expected = Time.utc(y, mo, d, h.to_i, mi.to_i, s.to_i) + Rational(usec, 1_000_000)

        actual = @client.query("SELECT CAST('#{literal}' AS DATETIME(6)) AS t", database_timezone: :utc).first['t']
        expect(actual).to eql(expected), "#{literal}: expected #{expected.inspect}, got #{actual.inspect}"
        expect(actual.utc_offset).to eql(0)
        expect(actual.usec).to eql(usec)
      end
    end

    it "should normalise invalid-but-in-range :utc DATETIME values exactly as Time.utc does" do
      # With ALLOW_INVALID_DATES the server hands back dates that are canonical
      # in shape but not real calendar days. Time.utc does not reject these --
      # it normalises them (Feb 31 becomes Mar 3) -- so the arithmetic path must
      # land on the same instant rather than on its own idea of the date.
      client = new_client
      client.query("SET SESSION sql_mode='ALLOW_INVALID_DATES'")
      {
        '2023-02-31 12:00:00' => Time.utc(2023, 3, 3, 12, 0, 0),
        '2023-04-31 01:02:03' => Time.utc(2023, 5, 1, 1, 2, 3),
        '2023-02-29 00:00:00' => Time.utc(2023, 3, 1, 0, 0, 0),
        '2023-11-31 23:59:59' => Time.utc(2023, 12, 1, 23, 59, 59),
        '2024-02-30 06:30:00' => Time.utc(2024, 3, 1, 6, 30, 0),
      }.each do |literal, expected|
        actual = client.query("SELECT CAST('#{literal}' AS DATETIME) AS t", database_timezone: :utc).first['t']
        expect(actual).to eql(expected), "#{literal}: expected #{expected.inspect}, got #{actual.inspect}"
      end
    end

    it "should leave :local DATETIME handling on the generic path" do
      literal = '2026-07-28 12:34:56'
      actual = @client.query("SELECT CAST('#{literal}' AS DATETIME) AS t", database_timezone: :local).first['t']
      expect(actual).to eql(Time.local(2026, 7, 28, 12, 34, 56))
      expect(actual.utc_offset).to eql(Time.local(2026, 7, 28, 12, 34, 56).utc_offset)
    end

    it "should parse DATE values identically to the sscanf path" do
      # 1000-01-01 and 9999-12-31 are MySQL's DATE range edges.
      ['2026-07-28', '1000-01-01', '9999-12-31'].each do |literal|
        row = @client.query("SELECT CAST('#{literal}' AS DATE) AS d").first['d']
        expect(row).to be_an_instance_of(Date)
        expect(row.strftime('%Y-%m-%d')).to eql(literal)
      end
    end

    it "should return Time for a TIME value" do
      expect(test_result['time_test']).to be_an_instance_of(Time)
      expect(test_result['time_test'].strftime("%Y-%m-%d %H:%M:%S")).to eql('2000-01-01 11:44:00')
    end

    it "should return Date for a DATE value" do
      expect(test_result['date_test']).to be_an_instance_of(Date)
      expect(test_result['date_test'].strftime("%Y-%m-%d")).to eql('2010-04-04')
    end

    it "should return String for an ENUM value" do
      expect(test_result['enum_test']).to be_an_instance_of(String)
      expect(test_result['enum_test']).to eql('val1')
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
          expect(result['enum_test'].encoding).to eql(Encoding::ASCII)
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
          expect(result['set_test'].encoding).to eql(Encoding::ASCII)
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
              expect(result[field].encoding).to eql(Encoding::ASCII)
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

  context "server flags" do
    let(:test_result) { @client.query("SELECT * FROM mysql2_test ORDER BY null_test DESC LIMIT 1") }

    it "should set a definitive value for query_was_slow" do
      expect(test_result.server_flags[:query_was_slow]).to eql(false)
    end
    it "should set a definitive value for no_index_used" do
      expect(test_result.server_flags[:no_index_used]).to eql(true)
    end
    it "should set a definitive value for no_good_index_used" do
      expect(test_result.server_flags[:no_good_index_used]).to eql(false)
    end
  end

  context 'garbage collection ordering' do
    # Regression coverage for the deferred pending-free queue (see
    # mysql2_enqueue_pending_result_free / mysql2_reap_pending_result_frees
    # in ext/mysql2/client.c, and rb_mysql_result_free_result in
    # ext/mysql2/result.c). A streaming Result (:stream => true) that is
    # abandoned mid-iteration -- the caller breaks out of #each, or simply
    # never finishes reading it -- still holds an open cursor with unread
    # rows on the wire when it becomes GC-eligible. Before this fix, the
    # Result's GC free function called mysql_free_result/
    # mysql_stmt_free_result directly, which for such a cursor may read and
    # discard the remaining rows over the network (flush_use_result) --
    # blocking I/O from a dfree callback that can run mid-GC-sweep, possibly
    # while the same connection is mid protocol exchange for a completely
    # unrelated command. See also the "garbage collection ordering" context
    # in statement_spec.rb for the sibling statement-close hazard.
    #
    # A small, fast loopback connection doesn't reliably reproduce the
    # network-corruption failure mode even without this fix: there just
    # isn't much of a timing window to hit. These specs lean on GC.stress
    # and a larger streamed row count to widen that window as far as
    # practical, but they are regression coverage for the deferred-free
    # bookkeeping (no crash, no corrupted results, queue drains to zero)
    # rather than a guaranteed repro of the underlying race.

    # A recursive CTE with several hundred rows, so breaking out of #each
    # early genuinely leaves rows unread on the wire (the fixture table
    # mysql2_test only ever has a single row).
    let(:big_stream_sql) do
      'WITH RECURSIVE seq AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM seq WHERE n < 500) SELECT n FROM seq'
    end

    it 'does not corrupt later queries when an abandoned streaming result is collected mid-stream' do
      begin
        GC.stress = true
        30.times do |i|
          result = @client.query(big_stream_sql, stream: true, cache_rows: false)
          count = 0
          result.each do |_row|
            count += 1
            break if count == 3
          end
          result = nil # rubocop:disable Lint/UselessAssignment

          expect(@client.query("SELECT #{i} AS n").first['n']).to eq(i)
        end
      ensure
        GC.stress = false
      end
    end

    it 'does not corrupt later queries when an abandoned streaming prepared statement result is collected mid-stream' do
      begin
        GC.stress = true
        30.times do |i|
          stmt = @client.prepare(big_stream_sql)
          result = stmt.execute(stream: true, cache_rows: false)
          count = 0
          result.each do |_row|
            count += 1
            break if count == 3
          end
          result = nil # rubocop:disable Lint/UselessAssignment
          stmt = nil # rubocop:disable Lint/UselessAssignment

          expect(@client.query("SELECT #{i} AS n").first['n']).to eq(i)
        end
      ensure
        GC.stress = false
      end
    end

    it 'drains #pending_result_frees to zero at the next safe point' do
      # A plain GC.start right after dropping the reference doesn't reliably
      # collect a Result that a C extension method (#first) just touched --
      # conservative stack scanning can keep it artificially reachable for a
      # while. GC.stress forces the issue on every subsequent allocation,
      # same as the specs above.
      begin
        GC.stress = true
        30.times do
          result = @client.query(big_stream_sql, stream: true, cache_rows: false)
          result.first
          result = nil # rubocop:disable Lint/UselessAssignment
        end
      ensure
        GC.stress = false
      end

      GC.start
      @client.ping
      expect(@client.pending_result_frees).to eq(0)
    end
  end
end
