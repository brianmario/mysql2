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
  end

  context "metadata queries" do
    it "should show tables" do
      @result = @client.query "SHOW TABLES"
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

    context "when iterated repeatedly" do
      def collect_rows(result, **overrides)
        [].tap { |rows| result.each(**overrides) { |row| rows << row } }
      end

      it "should replay identical row objects when cache_rows is enabled" do
        result = @client.query "SELECT 1 AS a UNION SELECT 2"
        first = collect_rows(result)
        second = collect_rows(result)
        expect(second).to eql(first)
        expect(second.map(&:object_id)).to eql(first.map(&:object_id))
      end

      it "should build fresh row objects each time when cache_rows is disabled" do
        result = @client.query "SELECT 1 AS a UNION SELECT 2", cache_rows: false
        first = collect_rows(result)
        second = collect_rows(result)
        expect(second).to eql(first)
        expect(second.map(&:object_id)).not_to eql(first.map(&:object_id))
      end

      it "should apply the original query options to a plain #each after a per-each override" do
        result = @client.query "SELECT 1 AS a", cache_rows: false
        expect(collect_rows(result)).to eql([{ "a" => 1 }])
        expect(collect_rows(result, as: :array)).to eql([[1]])
        expect(collect_rows(result, cast: false)).to eql([{ "a" => "1" }])
        expect(collect_rows(result)).to eql([{ "a" => 1 }])
      end

      it "should apply the original query options to a plain #each when a per-each override came first" do
        result = @client.query "SELECT 1 AS a", cache_rows: false
        expect(collect_rows(result, as: :array)).to eql([[1]])
        expect(collect_rows(result)).to eql([{ "a" => 1 }])
      end

      it "should keep the key style chosen by the first iteration regardless of later overrides" do
        # Field-name VALUEs are cached per result by the first iteration
        # (rb_mysql_result_fetch_field), so a later per-each :symbolize_keys
        # override never re-keys rows: the first iteration's key style wins.
        # Longstanding upstream behavior, pinned so the parsed-options cache
        # cannot change it in either direction.
        result = @client.query "SELECT 1 AS a", cache_rows: false
        expect(collect_rows(result)).to eql([{ "a" => 1 }])
        expect(collect_rows(result, symbolize_keys: true)).to eql([{ "a" => 1 }])

        result = @client.query "SELECT 1 AS a", cache_rows: false
        expect(collect_rows(result, symbolize_keys: true)).to eql([{ a: 1 }])
        expect(collect_rows(result)).to eql([{ a: 1 }])
      end

      it "should replay cached rows built with the original options even when a later #each passes overrides" do
        result = @client.query "SELECT 1 AS a"
        expect(collect_rows(result)).to eql([{ "a" => 1 }])
        expect(collect_rows(result, symbolize_keys: true)).to eql([{ "a" => 1 }])
      end

      it "should reject a negative :rows_per_gvl_yield on every #each, not just the first" do
        result = @client.query "SELECT 1", rows_per_gvl_yield: -1
        2.times do
          expect { result.each { |_| } }.to raise_error(Mysql2::Error, /rows_per_gvl_yield/)
        end
      end

      it "should reject a negative per-each :rows_per_gvl_yield even after a successful plain #each" do
        result = @client.query "SELECT 1"
        result.each { |_| }
        expect { result.each(rows_per_gvl_yield: -1) { |_| } }.to raise_error(Mysql2::Error, /rows_per_gvl_yield/)
      end
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

    context "when iterating in array mode" do
      # Array rows never contain field names, so names are batch-materialized
      # on the first fetched row instead of fetched per cell. These pin that
      # #fields behaves exactly as it did with the per-cell materialization,
      # including after an abandoned stream is force-freed by the next query.
      let(:sql) { "SELECT 1 AS a, 'x' AS b UNION SELECT 2, 'y' UNION SELECT 3, 'z'" }

      it "should return field names after buffered iteration" do
        result = @client.query(sql, as: :array)
        result.to_a
        expect(result.fields).to eql(%w[a b])
      end

      it "should return field names after streaming iteration" do
        result = @client.query(sql, as: :array, stream: true, cache_rows: false)
        result.each { |_| }
        expect(result.fields).to eql(%w[a b])
      end

      it "should fully populate fields when iteration breaks after the first row" do
        result = @client.query(sql, as: :array, cache_rows: false)
        result.each { |_| break } # rubocop:disable Lint/UnreachableLoop
        expect(result.fields).to eql(%w[a b])
      end

      it "should fully populate fields when the block raises mid-iteration" do
        result = @client.query(sql, as: :array, cache_rows: false)
        expect { result.each { |_| raise "boom" } }.to raise_error(RuntimeError, "boom") # rubocop:disable Lint/UnreachableLoop
        expect(result.fields).to eql(%w[a b])
      end

      it "should keep fields accessible after an abandoned stream is force-freed by the next query" do
        # The next query force-frees the abandoned stream without the
        # natural-completion metadata caching, so the names materialized by
        # the first fetched row are the only copy left.
        result = @client.query(sql, as: :array, stream: true, cache_rows: false)
        result.each { |_| break } # rubocop:disable Lint/UnreachableLoop
        @client.query("SELECT 1")
        expect(result.fields).to eql(%w[a b])
      end

      it "should keep raising for a never-iterated stream force-freed by the next query" do
        # No row was ever fetched, so no names were materialized to survive
        # the force-free.
        result = @client.query(sql, as: :array, stream: true, cache_rows: false)
        @client.query("SELECT 1")
        expect { result.fields }.to raise_error(Mysql2::Error, "Result set has already been freed")
      end

      it "should honor per-each symbolize_keys in fields" do
        result = @client.query(sql)
        result.each(as: :array, symbolize_keys: true) { |_| }
        expect(result.fields).to eql(%i[a b])
      end

      it "should honor per-each symbolize_keys in fields after a force-freed abandoned stream" do
        result = @client.query(sql, stream: true, cache_rows: false)
        result.each(as: :array, symbolize_keys: true) { |_| break } # rubocop:disable Lint/UnreachableLoop
        @client.query("SELECT 1")
        expect(result.fields).to eql(%i[a b])
      end

      it "should keep fields accessible for exhausted empty results" do
        result = @client.query("SELECT 1 AS a, 'x' AS b WHERE 1 = 0", as: :array)
        expect(result.to_a).to eql([])
        expect(result.fields).to eql(%w[a b])
      end

      it "should keep fields accessible for exhausted empty streaming results" do
        result = @client.query("SELECT 1 AS a, 'x' AS b WHERE 1 = 0", as: :array, stream: true, cache_rows: false)
        expect(result.each.to_a).to eql([])
        expect(result.fields).to eql(%w[a b])
      end
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

  context "#tables" do
    let(:test_result) { @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1") }

    it "method should exist" do
      expect(test_result).to respond_to(:tables)
    end

    it "should return an array of table names in proper order" do
      result = @client.query("SELECT id, bit_test, single_bit_test FROM mysql2_test ORDER BY id DESC LIMIT 1")
      expect(result.tables).to eql(%w[mysql2_test mysql2_test mysql2_test])
    end

    it "should return an array of frozen strings" do
      result = @client.query "SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1"
      result.tables.each do |f|
        expect(f).to be_frozen
      end
    end
  end

  context "#dbs" do
    let(:test_result) { @client.query("SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1") }

    it "method should exist" do
      expect(test_result).to respond_to(:dbs)
    end

    it "should return an array of database names in proper order" do
      db = DatabaseCredentials['root']['database']
      result = @client.query("SELECT id, bit_test, single_bit_test FROM mysql2_test ORDER BY id DESC LIMIT 1")
      expect(result.dbs).to eql([db, db, db])
    end

    it "should return an array of frozen strings" do
      result = @client.query "SELECT * FROM mysql2_test ORDER BY id DESC LIMIT 1"
      result.dbs.each do |f|
        expect(f).to be_frozen
      end
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

    context "casting integer columns" do
      before do
        @client.query <<-SQL
          CREATE TEMPORARY TABLE mysql2_int_cast_test (
            tiny_int TINYINT, tiny_uint TINYINT UNSIGNED,
            small_int SMALLINT, small_uint SMALLINT UNSIGNED,
            medium_int MEDIUMINT, medium_uint MEDIUMINT UNSIGNED,
            int_col INT, uint_col INT UNSIGNED,
            big_int BIGINT, big_uint BIGINT UNSIGNED,
            year_col YEAR
          )
        SQL
      end

      def roundtrip(column, value, **query_options)
        @client.query "DELETE FROM mysql2_int_cast_test"
        @client.query "INSERT INTO mysql2_int_cast_test (#{column}) VALUES (#{value})"
        @client.query("SELECT #{column} AS v FROM mysql2_int_cast_test", **query_options).first['v']
      end

      boundaries = {
        'tiny_int'    => [-128, -1, 0, 1, 127],
        'tiny_uint'   => [0, 255],
        'small_int'   => [-32_768, 32_767],
        'small_uint'  => [0, 65_535],
        'medium_int'  => [-8_388_608, 8_388_607],
        'medium_uint' => [0, 16_777_215],
        'int_col'     => [-2_147_483_648, 2_147_483_647],
        'uint_col'    => [0, 4_294_967_295],
        'big_int'     => [-9_223_372_036_854_775_808, -9_223_372_036_854_775_807,
                          9_223_372_036_854_775_806, 9_223_372_036_854_775_807,],
        'big_uint'    => [0, 9_223_372_036_854_775_807, 9_223_372_036_854_775_808,
                          18_446_744_073_709_551_614, 18_446_744_073_709_551_615,],
        'year_col'    => [1901, 2000, 2155],
      }.freeze

      it "returns exact Integers at every signed and unsigned column boundary" do
        boundaries.each do |column, values|
          values.each do |value|
            returned = roundtrip(column, value)
            expect(returned).to be_an_instance_of(Integer)
            expect(returned).to eql(value)
          end
        end
      end

      it "matches Ruby integer values across every power-of-ten boundary" do
        signed_range = -9_223_372_036_854_775_808..9_223_372_036_854_775_807
        signed = []
        unsigned = [18_446_744_073_709_551_614, 18_446_744_073_709_551_615]
        (0..19).each do |k|
          power = 10**k
          [power - 1, power, power + 1].each do |v|
            signed.push(v, -v) if signed_range.cover?(v)
            unsigned.push(v) if v <= 18_446_744_073_709_551_615
          end
        end
        signed = signed.uniq.sort
        unsigned = unsigned.uniq.sort

        @client.query "INSERT INTO mysql2_int_cast_test (big_int) VALUES #{signed.map { |v| "(#{v})" }.join(',')}"
        returned = @client.query("SELECT big_int AS v FROM mysql2_int_cast_test ORDER BY v").map { |row| row['v'] }
        expect(returned).to eql(signed)

        @client.query "DELETE FROM mysql2_int_cast_test"
        @client.query "INSERT INTO mysql2_int_cast_test (big_uint) VALUES #{unsigned.map { |v| "(#{v})" }.join(',')}"
        returned = @client.query("SELECT big_uint AS v FROM mysql2_int_cast_test ORDER BY v").map { |row| row['v'] }
        expect(returned).to eql(unsigned)
      end

      it "returns exact boundary values when streaming" do
        expect(roundtrip('big_int', -9_223_372_036_854_775_808, stream: true, cache_rows: false)) \
          .to eql(-9_223_372_036_854_775_808)
        expect(roundtrip('big_uint', 18_446_744_073_709_551_615, stream: true, cache_rows: false)) \
          .to eql(18_446_744_073_709_551_615)
      end

      it "returns boundary values as Strings when :cast is false" do
        expect(roundtrip('big_int', -9_223_372_036_854_775_808, cast: false)).to eql("-9223372036854775808")
        expect(roundtrip('big_uint', 18_446_744_073_709_551_615, cast: false)).to eql("18446744073709551615")
      end

      it "returns exact boundary values from prepared statements" do
        @client.query "INSERT INTO mysql2_int_cast_test (big_int, big_uint) VALUES " \
                      "(-9223372036854775808, 18446744073709551615)"
        row = @client.prepare("SELECT big_int, big_uint FROM mysql2_int_cast_test").execute.first
        expect(row['big_int']).to eql(-9_223_372_036_854_775_808)
        expect(row['big_uint']).to eql(18_446_744_073_709_551_615)
      end

      it "casts DECIMAL(65,0) values beyond 64-bit range to Integer" do
        [10**65 - 1, -(10**65 - 1), 123_456_789_012_345_678_901, -123_456_789_012_345_678_901].each do |value|
          returned = @client.query("SELECT CAST('#{value}' AS DECIMAL(65,0)) AS v").first['v']
          expect(returned).to be_an_instance_of(Integer)
          expect(returned).to eql(value)
        end
      end

      it "returns exact values for ZEROFILL columns despite leading zeros" do
        @client.query "CREATE TEMPORARY TABLE mysql2_zerofill_test (zf INT ZEROFILL)"
        @client.query "INSERT INTO mysql2_zerofill_test (zf) VALUES (42), (4294967295)"
        returned = @client.query("SELECT zf FROM mysql2_zerofill_test ORDER BY zf").map { |row| row['zf'] }
        expect(returned).to eql([42, 4_294_967_295])
      end
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

  context "string value encodings across character sets" do
    # Exercises the per-process charsetnr -> Ruby encoding index cache and the
    # per-Result connection-encoding cache in ext/mysql2/result.c.
    # `SET character_set_results = NULL` stops the server from converting
    # result values to the connection's character set, so every field below
    # arrives tagged with its own charsetnr -- including collation ids above
    # 255 (utf8mb4_ja_0900_as_cs is id 303), which only resolve because the
    # cache is sized to the full mapping table rather than one byte.
    #
    # The 0900 collations are MySQL 8.0+ only. MariaDB cannot pin the >255
    # slots at all: its only collation ids above 255 (the uca1400 family,
    # ids 2304+) lie beyond the mapping table entirely and take the
    # connection-encoding fallback, so that column is skipped there.
    let(:server_supports_0900_collations) do
      server_info = @client.server_info
      !server_info[:version].include?('MariaDB') && server_info[:id] >= 80000
    end

    let(:charset_matrix_sql) do
      fields = [
        "_utf8mb4 0x68C3A96C6C6F AS utf8mb4_val",
        "CONVERT(_utf8mb4 0x68C3A96C6C6F USING latin1) AS latin1_val",
        "CONVERT('abc' USING latin2) AS latin2_val",
        "CONVERT('abc' USING greek) AS greek_val",
        "CONVERT('abc' USING koi8r) AS koi8r_val",
        "CONVERT('abc' USING ascii) AS ascii_val",
        "CONVERT(_utf8mb4 0xE38182 USING sjis) AS sjis_val",
        "CONVERT(_utf8mb4 0xE38182 USING cp932) AS cp932_val",
        "CONVERT('abc' USING big5) AS big5_val",
        "CONVERT('abc' USING gb2312) AS gb2312_val",
        "UNHEX('DEADBEEF') AS binary_val",
        "CONVERT('abc' USING dec8) AS dec8_val",
      ]
      fields << "_utf8mb4 0xE38182 COLLATE utf8mb4_ja_0900_as_cs AS ja_collation_val" \
        if server_supports_0900_collations
      "SELECT #{fields.join(', ')}"
    end

    # Expected bytes and encoding per field. dec8 (charsetnr 3) has no entry
    # in the mapping table, so it falls back to the connection's encoding.
    let(:charset_matrix_expected) do
      {
        'utf8mb4_val' => ["h\xC3\xA9llo", Encoding::UTF_8],
        'latin1_val'  => ["h\xE9llo", Encoding::ISO_8859_1],
        'latin2_val'  => ['abc', Encoding::ISO_8859_2],
        'greek_val'   => ['abc', Encoding::ISO_8859_7],
        'koi8r_val'   => ['abc', Encoding::KOI8_R],
        'ascii_val'   => ['abc', Encoding::US_ASCII],
        'sjis_val'    => ["\x82\xA0", Encoding::Shift_JIS],
        'cp932_val'   => ["\x82\xA0", Encoding::Windows_31J],
        'big5_val'    => ['abc', Encoding::Big5],
        'gb2312_val'  => ['abc', Encoding::GB2312],
        'binary_val'  => ["\xDE\xAD\xBE\xEF", Encoding::BINARY],
        'dec8_val'    => ['abc', Encoding::UTF_8],
      }.tap do |expected|
        expected['ja_collation_val'] = ["\xE3\x81\x82", Encoding::UTF_8] if server_supports_0900_collations
      end
    end

    def expect_charset_matrix_row(row)
      expect(row.keys).to match_array(charset_matrix_expected.keys)
      row.each do |name, value|
        bytes, encoding = charset_matrix_expected[name]
        expect(value.encoding).to eql(encoding), "#{name}: expected #{encoding}, got #{value.encoding}"
        expect(value.b).to eql(bytes.b), "#{name}: expected #{bytes.b.inspect}, got #{value.b.inspect}"
      end
    end

    it "tags each field with its own character set, consistently across repeated queries" do
      with_internal_encoding nil do
        @client.query("SET character_set_results = NULL")
        2.times do
          expect_charset_matrix_row(@client.query(charset_matrix_sql).first)
        end
      end
    end

    it "converts every non-binary field to Encoding.default_internal when set" do
      with_internal_encoding Encoding::UTF_8 do
        @client.query("SET character_set_results = NULL")
        row = @client.query(charset_matrix_sql).first
        row.each do |name, value|
          expected = name == 'binary_val' ? Encoding::BINARY : Encoding::UTF_8
          expect(value.encoding).to eql(expected), "#{name}: expected #{expected}, got #{value.encoding}"
        end
        expect(row['latin1_val']).to eql("héllo")
        expect(row['sjis_val']).to eql("あ")
      end
    end

    it "applies the same encodings through the prepared statement path" do
      with_internal_encoding nil do
        @client.query("SET character_set_results = NULL")
        stmt = @client.prepare(charset_matrix_sql)
        2.times do
          expect_charset_matrix_row(stmt.execute.first)
        end
      end
    end

    it "applies the same encodings while streaming" do
      with_internal_encoding nil do
        @client.query("SET character_set_results = NULL")
        rows = @client.query(charset_matrix_sql, stream: true, cache_rows: false).to_a
        expect(rows.length).to eql(1)
        expect_charset_matrix_row(rows.first)
      end
    end

    context "for table columns of differing character sets" do
      before(:example) do
        @client.query(
          "CREATE TEMPORARY TABLE mysql2_enc_matrix_test (" \
          "utf8mb4_col VARCHAR(20) CHARACTER SET utf8mb4, " \
          "latin1_col VARCHAR(20) CHARACTER SET latin1, " \
          "blob_col BLOB)",
        )
        @client.query("INSERT INTO mysql2_enc_matrix_test VALUES ('héllo', 'héllo', UNHEX('DEADBEEF'))")
        @client.query("SET character_set_results = NULL")
      end

      it "tags each column with its column character set if Encoding.default_internal is nil" do
        with_internal_encoding nil do
          row = @client.query("SELECT * FROM mysql2_enc_matrix_test").first
          expect(row['utf8mb4_col']).to eql("héllo")
          expect(row['utf8mb4_col'].encoding).to eql(Encoding::UTF_8)
          expect(row['latin1_col'].b).to eql("h\xE9llo".b)
          expect(row['latin1_col'].encoding).to eql(Encoding::ISO_8859_1)
          expect(row['blob_col'].encoding).to eql(Encoding::BINARY)
        end
      end

      it "converts text columns but not blobs to Encoding.default_internal" do
        with_internal_encoding Encoding::UTF_8 do
          row = @client.query("SELECT * FROM mysql2_enc_matrix_test").first
          expect(row['utf8mb4_col']).to eql("héllo")
          expect(row['latin1_col']).to eql("héllo")
          expect(row['latin1_col'].encoding).to eql(Encoding::UTF_8)
          expect(row['blob_col'].encoding).to eql(Encoding::BINARY)
        end
      end
    end

    it "captures Encoding.default_internal at each #each call, not per row" do
      # Deliberate behavior pin: Encoding.default_internal is read once at
      # #each entry (per call) instead of once per row. Changing it from
      # inside the iteration block no longer affects later rows of that same
      # call; the next #each call observes the new value.
      with_internal_encoding nil do
        result = @client.query("SELECT 'a' AS s UNION ALL SELECT 'b' UNION ALL SELECT 'c'", cache_rows: false)

        first_pass = []
        result.each do |row|
          first_pass << row['s'].encoding
          old_verbose = $VERBOSE
          $VERBOSE = nil
          Encoding.default_internal = Encoding::ISO_8859_1
          $VERBOSE = old_verbose
        end
        expect(first_pass).to eql([Encoding::UTF_8] * 3)

        # cache_rows: false forces the second #each to re-materialize rows
        # from the C result set, capturing the new default_internal.
        second_pass = result.map { |row| row['s'].encoding }
        expect(second_pass).to eql([Encoding::ISO_8859_1] * 3)
      end
    end
  end

  context "with the :force_encoding query option" do
    # 0x68C3A96C6C6F is "héllo" in UTF-8.
    let(:sql) { "SELECT _utf8mb4 0x68C3A96C6C6F AS utf8_val, UNHEX('DEADBEEF') AS binary_val" }

    it "retags string values with the forced encoding, bytes unchanged" do
      plain = @client.query(sql).first
      forced = @client.query(sql, force_encoding: Encoding::ISO_8859_1).first
      expect(forced['utf8_val'].encoding).to eql(Encoding::ISO_8859_1)
      expect(forced['utf8_val'].bytes).to eql(plain['utf8_val'].bytes)
    end

    it "accepts an encoding name as a String" do
      row = @client.query(sql, force_encoding: 'ISO-8859-1').first
      expect(row['utf8_val'].encoding).to eql(Encoding::ISO_8859_1)
    end

    it "retags BLOB/binary values instead of leaving them ASCII-8BIT" do
      row = @client.query(sql, force_encoding: 'utf-8').first
      expect(row['binary_val'].encoding).to eql(Encoding::UTF_8)
      expect(row['binary_val'].bytes).to eql([0xDE, 0xAD, 0xBE, 0xEF])
    end

    it "wins over Encoding.default_internal: retag only, no transcode" do
      with_internal_encoding Encoding::UTF_8 do
        row = @client.query(sql, force_encoding: Encoding::ISO_8859_1).first
        expect(row['utf8_val'].encoding).to eql(Encoding::ISO_8859_1)
        expect(row['utf8_val'].bytes).to eql("h\xC3\xA9llo".bytes)
      end
    end

    it "applies to streaming results" do
      rows = @client.query(sql, stream: true, cache_rows: false, force_encoding: 'binary').to_a
      expect(rows.first['utf8_val'].encoding).to eql(Encoding::BINARY)
      expect(rows.first['binary_val'].encoding).to eql(Encoding::BINARY)
    end

    it "retags every value under cast: false, where numbers arrive as strings" do
      row = @client.query("SELECT 1 AS int_val", cast: false, force_encoding: 'binary').first
      expect(row['int_val']).to eql("1")
      expect(row['int_val'].encoding).to eql(Encoding::BINARY)
    end

    it "does not affect values cast to non-string types" do
      row = @client.query("SELECT 1 AS int_val, DATE'2026-08-11' AS date_val", force_encoding: 'binary').first
      expect(row['int_val']).to eql(1)
      expect(row['date_val']).to eql(Date.new(2026, 8, 11))
    end

    it "does not affect field names" do
      result = @client.query(sql, symbolize_keys: true, force_encoding: 'binary')
      expect(result.first.keys).to eql(%i[utf8_val binary_val])

      result = @client.query(sql, force_encoding: 'binary')
      expect(result.fields).to eql(%w[utf8_val binary_val])
      expect(result.fields.first.encoding).to eql(Encoding::UTF_8)
    end

    it "raises for an unknown encoding name before the command is sent" do
      @client.query("CREATE TEMPORARY TABLE mysql2_force_encoding_probe (id INT)")
      expect { @client.query("INSERT INTO mysql2_force_encoding_probe VALUES (1)", force_encoding: 'not-an-encoding') }
        .to raise_error(ArgumentError, /unknown encoding name.*not-an-encoding/)
      # Nothing hit the wire: the INSERT never ran and the connection is
      # still usable.
      expect(@client.query("SELECT COUNT(*) AS n FROM mysql2_force_encoding_probe").first['n']).to eql(0)
    end

    it "raises for values that are not encodings" do
      expect { @client.query(sql, force_encoding: 42) }.to raise_error(TypeError)
    end

    it "snapshots the option at query time, immune to later mutation of the caller's hash" do
      name = +'binary'
      opts = { force_encoding: name }
      result = @client.query(sql, opts)
      name.replace('utf-8')
      opts[:force_encoding] = 'utf-8'
      expect(result.first['utf8_val'].encoding).to eql(Encoding::BINARY)
    end

    it "cannot be set per Result#each call" do
      result = @client.query(sql)
      expect { result.each(force_encoding: 'utf-8') {} }
        .to raise_error(Mysql2::Error, ":force_encoding is a query option and cannot be set on Result#each")
      # Presence of the key is the error, even with a nil value.
      expect { result.each(force_encoding: nil) {} }
        .to raise_error(Mysql2::Error, ":force_encoding is a query option and cannot be set on Result#each")
      # The result is still iterable, including with other per-each options.
      expect(result.each(as: :array).first.first.encoding).to eql(Encoding::UTF_8)
    end

    it "carries through re-iteration with per-each options" do
      result = @client.query(sql, force_encoding: 'binary', cache_rows: false)
      rows = []
      result.each(as: :array) { |row| rows << row }
      expect(rows.first.first.encoding).to eql(Encoding::BINARY)
    end
  end

  context "cast: false raw string rows" do
    # Pins the text-protocol cast: false fast path in rb_mysql_result_fetch_row
    # (ext/mysql2/result.c) to the exact output of the casting loop's raw-string
    # arm it replaced: every non-NULL value is a String of the wire bytes,
    # length-based (embedded NULs intact), tagged by
    # mysql2_set_field_string_encoding; every NULL is nil. Expected values are
    # written as literals -- bytes and encoding both -- rather than derived
    # from another code path at runtime.
    #
    # Encoding notes, verified against the casting path's raw-string arm on
    # this server: numeric fields (INT/BIGINT/DECIMAL/FLOAT/YEAR/TINYINT/BIT)
    # arrive with charsetnr 63 but no BINARY_FLAG, so they are tagged BINARY
    # via the charsetnr mapping and (unlike BINARY_FLAG fields) do transcode
    # under Encoding.default_internal. Temporal fields and the true binary
    # columns (BLOB/VARBINARY) carry BINARY_FLAG + charsetnr 63 and stay
    # BINARY unconditionally. latin1 text arrives converted to the connection
    # charset (utf8mb4) unless character_set_results is disabled.
    before(:example) do
      @client.query %[
        CREATE TEMPORARY TABLE mysql2_cast_false_test (
          row_id TINYINT NOT NULL,
          int_min_col INT,
          bigint_umax_col BIGINT UNSIGNED,
          decimal_col DECIMAL(10,3),
          float_col FLOAT(10,3),
          date_col DATE,
          datetime_col DATETIME(6),
          time_col TIME,
          year_col YEAR,
          bit_col BIT(64),
          tiny1_col TINYINT(1),
          varchar_utf8_col VARCHAR(32) CHARACTER SET utf8mb4,
          varchar_latin1_col VARCHAR(32) CHARACTER SET latin1,
          blob_col BLOB,
          varbinary_col VARBINARY(20)
        )
      ]
      @client.query %[
        INSERT INTO mysql2_cast_false_test VALUES
          (1, -2147483648, 18446744073709551615, 10.3, 10.3, '2010-04-04',
           '2010-04-04 11:44:00.123456', '-838:59:59', 2009, b'101', 1,
           'héllo ☃', 'héllo', _binary X'00DEADBEEF00FF', _binary X'760062'),
          (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           NULL, NULL, NULL, NULL),
          (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           '', '', '', '')
      ]
    end

    let(:parity_select) { "SELECT * FROM mysql2_cast_false_test ORDER BY row_id" }

    let(:column_names) do
      %w[
        row_id int_min_col bigint_umax_col decimal_col float_col date_col datetime_col time_col
        year_col bit_col tiny1_col varchar_utf8_col varchar_latin1_col blob_col varbinary_col
      ]
    end

    # Column name => [bytes, encoding] for values, nil for NULLs, in column
    # order. Row 1 exercises boundary numerics, fractional and extreme
    # temporals, embedded NUL bytes, and multibyte text; row 2 is NULL in
    # every non-key column; row 3 pins zero-length strings as distinct from
    # NULL.
    let(:expected_rows) do
      [
        {
          'row_id'             => ["1", Encoding::BINARY],
          'int_min_col'        => ["-2147483648", Encoding::BINARY],
          'bigint_umax_col'    => ["18446744073709551615", Encoding::BINARY],
          'decimal_col'        => ["10.300", Encoding::BINARY],
          'float_col'          => ["10.300", Encoding::BINARY],
          'date_col'           => ["2010-04-04", Encoding::BINARY],
          'datetime_col'       => ["2010-04-04 11:44:00.123456", Encoding::BINARY],
          'time_col'           => ["-838:59:59", Encoding::BINARY],
          'year_col'           => ["2009", Encoding::BINARY],
          'bit_col'            => ["\x00\x00\x00\x00\x00\x00\x00\x05", Encoding::BINARY],
          'tiny1_col'          => ["1", Encoding::BINARY],
          'varchar_utf8_col'   => ["héllo ☃", Encoding::UTF_8],
          'varchar_latin1_col' => ["héllo", Encoding::UTF_8],
          'blob_col'           => ["\x00\xDE\xAD\xBE\xEF\x00\xFF", Encoding::BINARY],
          'varbinary_col'      => ["v\x00b", Encoding::BINARY],
        },
        {
          'row_id' => ["2", Encoding::BINARY],
          'int_min_col' => nil, 'bigint_umax_col' => nil, 'decimal_col' => nil,
          'float_col' => nil, 'date_col' => nil, 'datetime_col' => nil,
          'time_col' => nil, 'year_col' => nil, 'bit_col' => nil,
          'tiny1_col' => nil, 'varchar_utf8_col' => nil,
          'varchar_latin1_col' => nil, 'blob_col' => nil, 'varbinary_col' => nil,
        },
        {
          'row_id' => ["3", Encoding::BINARY],
          'int_min_col' => nil, 'bigint_umax_col' => nil, 'decimal_col' => nil,
          'float_col' => nil, 'date_col' => nil, 'datetime_col' => nil,
          'time_col' => nil, 'year_col' => nil, 'bit_col' => nil,
          'tiny1_col' => nil,
          'varchar_utf8_col' => ["", Encoding::UTF_8],
          'varchar_latin1_col' => ["", Encoding::UTF_8],
          'blob_col' => ["", Encoding::BINARY],
          'varbinary_col' => ["", Encoding::BINARY],
        },
      ]
    end

    def expect_raw_row(row, expected, keys)
      expect(row.keys).to eql(keys) if row.is_a?(Hash)
      expected.each_with_index do |(name, expectation), i|
        value = row.is_a?(Hash) ? row[keys[i]] : row[i]
        if expectation.nil?
          expect(value).to be_nil, "#{name}: expected nil, got #{value.inspect}"
        else
          bytes, encoding = expectation
          expect(value).to be_an_instance_of(String), "#{name}: expected a String, got #{value.class}"
          expect(value.encoding).to eql(encoding), "#{name}: expected #{encoding}, got #{value.encoding}"
          expect(value.b).to eql(bytes.b), "#{name}: expected #{bytes.b.inspect}, got #{value.b.inspect}"
        end
      end
    end

    def expect_raw_rows(rows, keys)
      expect(rows.length).to eql(expected_rows.length)
      rows.zip(expected_rows) { |row, expected| expect_raw_row(row, expected, keys) }
    end

    [false, true].each do |stream|
      [false, true].each do |symbolize|
        variant = "stream: #{stream}, symbolize_keys: #{symbolize}"

        it "returns raw strings and nils in hash rows (#{variant})" do
          rows = @client.query(parity_select, cast: false, stream: stream, cache_rows: !stream, symbolize_keys: symbolize).to_a
          keys = symbolize ? column_names.map(&:to_sym) : column_names
          expect_raw_rows(rows, keys)
        end

        it "returns raw strings and nils in array rows (#{variant})" do
          result = @client.query(parity_select, cast: false, as: :array, stream: stream, cache_rows: !stream, symbolize_keys: symbolize)
          expect_raw_rows(result.to_a, column_names)
          expect(result.fields).to eql(symbolize ? column_names.map(&:to_sym) : column_names)
        end
      end
    end

    it "re-materializes identical rows when re-iterating with cache_rows: false" do
      result = @client.query(parity_select, cast: false, cache_rows: false)
      2.times { expect_raw_rows(result.to_a, column_names) }
    end

    it "preserves embedded NUL bytes: a strlen-based copy would truncate these" do
      row = @client.query(parity_select, cast: false).first
      expect(row['bit_col'].b).to eql("\x00\x00\x00\x00\x00\x00\x00\x05".b)
      expect(row['varbinary_col'].b).to eql("v\x00b".b)
      expect(row['blob_col'].bytesize).to eql(7)
    end

    it "keeps per-field charsetnr tagging when the server does not convert results" do
      @client.query("SET character_set_results = NULL")
      row = @client.query(parity_select, cast: false).first
      expect(row['varchar_latin1_col'].encoding).to eql(Encoding::ISO_8859_1)
      expect(row['varchar_latin1_col'].b).to eql("h\xE9llo".b)
      expect(row['varchar_utf8_col']).to eql("héllo ☃")
      expect(row['blob_col'].encoding).to eql(Encoding::BINARY)
    end

    it "applies Encoding.default_internal exactly as the casting path's raw strings do" do
      with_internal_encoding Encoding::UTF_8 do
        row = @client.query(parity_select, cast: false).first
        # BINARY_FLAG + charsetnr 63 fields never transcode...
        expect(row['blob_col'].encoding).to eql(Encoding::BINARY)
        expect(row['blob_col'].b).to eql("\x00\xDE\xAD\xBE\xEF\x00\xFF".b)
        expect(row['varbinary_col'].encoding).to eql(Encoding::BINARY)
        expect(row['date_col'].encoding).to eql(Encoding::BINARY)
        expect(row['datetime_col'].encoding).to eql(Encoding::BINARY)
        expect(row['time_col'].encoding).to eql(Encoding::BINARY)
        # ...while charsetnr-63-without-BINARY_FLAG numerics do,
        expect(row['int_min_col']).to eql("-2147483648")
        expect(row['int_min_col'].encoding).to eql(Encoding::UTF_8)
        expect(row['bit_col']).to eql("\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0005")
        expect(row['bit_col'].encoding).to eql(Encoding::UTF_8)
        # ...as does text (already converted to utf8mb4 by the server).
        expect(row['varchar_latin1_col']).to eql("héllo")
        expect(row['varchar_latin1_col'].encoding).to eql(Encoding::UTF_8)
      end
    end

    it "keeps #fields available after an abandoned cast: false stream is force-freed" do
      result = @client.query(parity_select, cast: false, as: :array, stream: true, cache_rows: false)
      result.each { |_| break } # rubocop:disable Lint/UnreachableLoop
      @client.query("SELECT 1") # force-frees the abandoned stream
      expect(result.fields).to eql(column_names)
    end

    it "does not fast-path prepared statements: cast: false still warns and fully casts" do
      statement = @client.prepare("SELECT int_min_col, date_col, varchar_utf8_col FROM mysql2_cast_false_test WHERE row_id = 1")
      row = nil
      expect { row = statement.execute(cast: false).first }
        .to output(/:cast is forced for prepared statements/).to_stderr
      expect(row['int_min_col']).to eql(-2147483648)
      expect(row['date_col']).to eql(Date.new(2010, 4, 4))
      expect(row['varchar_utf8_col']).to eql("héllo ☃")
    end
  end

  context "cast: :fast partially-cast rows" do
    # Pins the text-protocol cast: :fast mode in rb_mysql_result_fetch_row
    # (ext/mysql2/result.c) column by column:
    #
    # - Cast exactly as cast: true does: NULL, the integer family
    #   (TINYINT/SMALLINT/MEDIUMINT/INT/BIGINT/YEAR, signed and unsigned,
    #   ZEROFILL included), FLOAT/DOUBLE (via the same locale-independent
    #   Kernel#Float mechanism), BIT, and TINYINT(1)/BIT(1) booleans when
    #   :cast_booleans is on.
    # - Deferred as Strings of the wire bytes, tagged by
    #   mysql2_set_field_string_encoding exactly as cast: false tags them:
    #   DECIMAL/NEWDECIMAL (scale-0 included, an Integer under cast: true),
    #   DATE, DATETIME, TIMESTAMP, TIME.
    # - Everything else (text, blobs, enum, set, ...) is a String under
    #   cast: true already and is byte- and encoding-identical here.
    #
    # Expected values are literals -- bytes and encoding both -- rather than
    # derived from another code path at runtime.
    before(:example) do
      @client.query %[
        CREATE TEMPORARY TABLE mysql2_cast_fast_test (
          row_id TINYINT NOT NULL,
          bigint_min_col BIGINT,
          bigint_umax_col BIGINT UNSIGNED,
          int_zerofill_col INT UNSIGNED ZEROFILL,
          decimal_col DECIMAL(10,3),
          decimal_scale0_col DECIMAL(10,0),
          float_col FLOAT(10,3),
          double_col DOUBLE,
          date_col DATE,
          datetime_col DATETIME(6),
          timestamp_col TIMESTAMP(6) NULL,
          time_col TIME,
          year_col YEAR,
          bit_col BIT(64),
          single_bit_col BIT(1),
          tiny1_col TINYINT(1),
          varchar_utf8_col VARCHAR(32) CHARACTER SET utf8mb4,
          varchar_latin1_col VARCHAR(32) CHARACTER SET latin1,
          blob_col BLOB,
          varbinary_col VARBINARY(20)
        )
      ]
      @client.query %[
        INSERT INTO mysql2_cast_fast_test VALUES
          (1, -9223372036854775808, 18446744073709551615, 10, 10.3, 42,
           10.3, 10.3, '2010-04-04', '2010-04-04 11:44:00.123456',
           '2010-04-04 11:44:00.123456', '-838:59:59', 2009, b'101', b'1', 1,
           'héllo ☃', 'héllo', _binary X'00DEADBEEF00FF', _binary X'760062'),
          (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
          (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           NULL, NULL, NULL, NULL, NULL, '', '', '', '')
      ]
    end

    let(:fast_select) { "SELECT * FROM mysql2_cast_fast_test ORDER BY row_id" }

    let(:column_names) do
      %w[
        row_id bigint_min_col bigint_umax_col int_zerofill_col decimal_col decimal_scale0_col
        float_col double_col date_col datetime_col timestamp_col time_col year_col bit_col
        single_bit_col tiny1_col varchar_utf8_col varchar_latin1_col blob_col varbinary_col
      ]
    end

    # Column name => expectation, in column order. A two-element [bytes,
    # encoding] Array expects a String; nil expects nil; anything else is
    # compared with eql (class-sensitive, so 10 never passes for "10" or
    # 10.0). Row 1 exercises BIGINT boundaries (LLONG_MIN/ULLONG_MAX),
    # ZEROFILL padding, scale-0 DECIMAL, fractional and extreme temporals,
    # BIT with embedded NULs, and multibyte text; row 2 is NULL in every
    # non-key column; row 3 pins zero-length strings as distinct from NULL.
    let(:expected_rows) do
      [
        {
          'row_id'             => 1,
          'bigint_min_col'     => -9_223_372_036_854_775_808,
          'bigint_umax_col'    => 18_446_744_073_709_551_615,
          'int_zerofill_col'   => 10,
          'decimal_col'        => ["10.300", Encoding::BINARY],
          'decimal_scale0_col' => ["42", Encoding::BINARY],
          'float_col'          => 10.3,
          'double_col'         => 10.3,
          'date_col'           => ["2010-04-04", Encoding::BINARY],
          'datetime_col'       => ["2010-04-04 11:44:00.123456", Encoding::BINARY],
          'timestamp_col'      => ["2010-04-04 11:44:00.123456", Encoding::BINARY],
          'time_col'           => ["-838:59:59", Encoding::BINARY],
          'year_col'           => 2009,
          'bit_col'            => ["\x00\x00\x00\x00\x00\x00\x00\x05", Encoding::BINARY],
          'single_bit_col'     => ["\x01", Encoding::BINARY],
          'tiny1_col'          => 1,
          'varchar_utf8_col'   => ["héllo ☃", Encoding::UTF_8],
          'varchar_latin1_col' => ["héllo", Encoding::UTF_8],
          'blob_col'           => ["\x00\xDE\xAD\xBE\xEF\x00\xFF", Encoding::BINARY],
          'varbinary_col'      => ["v\x00b", Encoding::BINARY],
        },
        {
          'row_id' => 2,
          'bigint_min_col' => nil, 'bigint_umax_col' => nil, 'int_zerofill_col' => nil,
          'decimal_col' => nil, 'decimal_scale0_col' => nil, 'float_col' => nil,
          'double_col' => nil, 'date_col' => nil, 'datetime_col' => nil,
          'timestamp_col' => nil, 'time_col' => nil, 'year_col' => nil,
          'bit_col' => nil, 'single_bit_col' => nil, 'tiny1_col' => nil,
          'varchar_utf8_col' => nil, 'varchar_latin1_col' => nil,
          'blob_col' => nil, 'varbinary_col' => nil,
        },
        {
          'row_id' => 3,
          'bigint_min_col' => nil, 'bigint_umax_col' => nil, 'int_zerofill_col' => nil,
          'decimal_col' => nil, 'decimal_scale0_col' => nil, 'float_col' => nil,
          'double_col' => nil, 'date_col' => nil, 'datetime_col' => nil,
          'timestamp_col' => nil, 'time_col' => nil, 'year_col' => nil,
          'bit_col' => nil, 'single_bit_col' => nil, 'tiny1_col' => nil,
          'varchar_utf8_col' => ["", Encoding::UTF_8],
          'varchar_latin1_col' => ["", Encoding::UTF_8],
          'blob_col' => ["", Encoding::BINARY],
          'varbinary_col' => ["", Encoding::BINARY],
        },
      ]
    end

    def expect_fast_row(row, expected, keys)
      expect(row.keys).to eql(keys) if row.is_a?(Hash)
      expected.each_with_index do |(name, expectation), i|
        value = row.is_a?(Hash) ? row[keys[i]] : row[i]
        case expectation
        when nil
          expect(value).to be_nil, "#{name}: expected nil, got #{value.inspect}"
        when Array
          bytes, encoding = expectation
          expect(value).to be_an_instance_of(String), "#{name}: expected a String, got #{value.class}"
          expect(value.encoding).to eql(encoding), "#{name}: expected #{encoding}, got #{value.encoding}"
          expect(value.b).to eql(bytes.b), "#{name}: expected #{bytes.b.inspect}, got #{value.b.inspect}"
        else
          expect(value).to eql(expectation), "#{name}: expected #{expectation.inspect}, got #{value.inspect} (#{value.class})"
        end
      end
    end

    def expect_fast_rows(rows, keys)
      expect(rows.length).to eql(expected_rows.length)
      rows.zip(expected_rows) { |row, expected| expect_fast_row(row, expected, keys) }
    end

    [false, true].each do |stream|
      variant = "stream: #{stream}"

      it "casts cheap types and defers expensive ones in hash rows (#{variant})" do
        rows = @client.query(fast_select, cast: :fast, stream: stream, cache_rows: !stream).to_a
        expect_fast_rows(rows, column_names)
      end

      it "casts cheap types and defers expensive ones in array rows (#{variant})" do
        result = @client.query(fast_select, cast: :fast, as: :array, stream: stream, cache_rows: !stream)
        expect_fast_rows(result.to_a, column_names)
        expect(result.fields).to eql(column_names)
      end
    end

    it "re-materializes identical rows when re-iterating with cache_rows: false" do
      result = @client.query(fast_select, cast: :fast, cache_rows: false)
      2.times { expect_fast_rows(result.to_a, column_names) }
    end

    it "works as a per-each option the same way cast: false does" do
      result = @client.query(fast_select, cache_rows: false)
      rows = []
      result.each(cast: :fast) { |row| rows << row }
      expect_fast_rows(rows, column_names)
    end

    it "casts TINYINT(1) and BIT(1) as booleans when :cast_booleans is enabled" do
      row = @client.query(fast_select, cast: :fast, cast_booleans: true).first
      expect(row['tiny1_col']).to be true
      expect(row['single_bit_col']).to be true
      # The other cheap and deferred columns are unaffected.
      expect(row['bigint_min_col']).to eql(-9_223_372_036_854_775_808)
      expect(row['decimal_col']).to eql("10.300")
    end

    it "does not treat unrecognized truthy :cast values as :fast" do
      row = @client.query(fast_select, cast: :bogus).first
      expect(row['decimal_col']).to eql(BigDecimal("10.3"))
      expect(row['date_col']).to eql(Date.new(2010, 4, 4))
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

      it "still parses FLOAT and DOUBLE locale-independently" do
        row = @client.query("SELECT CAST(2.7 AS FLOAT) AS f, CAST(2.7 AS DOUBLE) AS d", cast: :fast).first
        expect(row['f']).to eql(2.7)
        expect(row['d']).to eql(2.7)
      end
    end

    it "keeps per-field charsetnr tagging when the server does not convert results" do
      @client.query("SET character_set_results = NULL")
      row = @client.query(fast_select, cast: :fast).first
      expect(row['varchar_latin1_col'].encoding).to eql(Encoding::ISO_8859_1)
      expect(row['varchar_latin1_col'].b).to eql("h\xE9llo".b)
      expect(row['decimal_col'].encoding).to eql(Encoding::BINARY)
      expect(row['date_col'].encoding).to eql(Encoding::BINARY)
    end

    it "applies Encoding.default_internal to deferred strings exactly as cast: false does" do
      with_internal_encoding Encoding::UTF_8 do
        row = @client.query(fast_select, cast: :fast).first
        # Temporal fields carry BINARY_FLAG + charsetnr 63 and never transcode...
        expect(row['date_col'].encoding).to eql(Encoding::BINARY)
        expect(row['datetime_col'].encoding).to eql(Encoding::BINARY)
        expect(row['time_col'].encoding).to eql(Encoding::BINARY)
        # ...while DECIMAL (charsetnr 63 without BINARY_FLAG) does,
        expect(row['decimal_col']).to eql("10.300")
        expect(row['decimal_col'].encoding).to eql(Encoding::UTF_8)
        # ...and BIT stays untagged raw bytes, exactly as under cast: true.
        expect(row['bit_col'].encoding).to eql(Encoding::BINARY)
        expect(row['bit_col'].b).to eql("\x00\x00\x00\x00\x00\x00\x00\x05".b)
      end
    end

    it "keeps #fields available after an abandoned cast: :fast stream is force-freed" do
      result = @client.query(fast_select, cast: :fast, as: :array, stream: true, cache_rows: false)
      result.each { |_| break } # rubocop:disable Lint/UnreachableLoop
      @client.query("SELECT 1") # force-frees the abandoned stream
      expect(result.fields).to eql(column_names)
    end

    it "does not fast-path prepared statements: cast: :fast still warns and fully casts" do
      statement = @client.prepare("SELECT decimal_col, date_col, bigint_min_col FROM mysql2_cast_fast_test WHERE row_id = 1")
      row = nil
      expect { row = statement.execute(cast: :fast).first }
        .to output(/:cast is forced for prepared statements/).to_stderr
      expect(row['decimal_col']).to eql(BigDecimal("10.3"))
      expect(row['date_col']).to eql(Date.new(2010, 4, 4))
      expect(row['bigint_min_col']).to eql(-9_223_372_036_854_775_808)
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

    it "returns the same hash object on every call" do
      expect(test_result.server_flags).to equal(test_result.server_flags)
    end

    it "is available on a frozen Result, even when frozen before first access" do
      test_result.freeze
      expect(test_result.server_flags).to eql(no_good_index_used: false, no_index_used: true, query_was_slow: false)
    end

    it "returns the same hash object after the Result is frozen" do
      flags = test_result.server_flags
      test_result.freeze
      expect(test_result.server_flags).to equal(flags)
    end

    it "is available after the result is fully iterated" do
      test_result.to_a
      expect(test_result.server_flags).to eql(no_good_index_used: false, no_index_used: true, query_was_slow: false)
    end

    it "is available after the result is freed" do
      test_result.free
      expect(test_result.server_flags).to eql(no_good_index_used: false, no_index_used: true, query_was_slow: false)
    end

    context "with multiple result sets" do
      before(:example) do
        @multi_client = new_client(flags: Mysql2::Client::MULTI_STATEMENTS)
      end

      it "reflects each result's own query, including results from store_result" do
        # First statement touches no table (no_index_used false); second is a
        # full scan (no_index_used true).
        first = @multi_client.query("SELECT 1 AS a; SELECT * FROM mysql2_test")
        expect(@multi_client.next_result).to be true
        second = @multi_client.store_result
        expect(@multi_client.next_result).to be false

        # Deliberately read the first result's flags only after the connection
        # has moved on to the second result: an implementation that read live
        # connection status at call time would leak the second statement's
        # full-scan flag into the first result here.
        expect(first.server_flags[:no_index_used]).to eql(false)
        expect(second.server_flags).to eql(no_good_index_used: false, no_index_used: true, query_was_slow: false)
      end
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
