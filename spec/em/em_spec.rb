# encoding: UTF-8
require 'spec_helper'
begin
  require 'eventmachine'
  require 'mysql2/em'

  describe Mysql2::EM::Client do
    test "supports async queries" do
      results = []
      EM.run do
        client1 = Mysql2::EM::Client.new DatabaseCredentials['root']
        defer1 = client1.query "SELECT sleep(0.1) as first_query"
        defer1.callback do |result|
          results << result.first
          client1.close
          EM.stop_event_loop
        end

        client2 = Mysql2::EM::Client.new DatabaseCredentials['root']
        defer2 = client2.query "SELECT sleep(0.025) second_query"
        defer2.callback do |result|
          results << result.first
          client2.close
        end
      end

      assert_includes results[0].keys, "second_query"
      assert_includes results[1].keys, "first_query"
    end

    test "supports queries in callbacks" do
      results = []
      EM.run do
        client = Mysql2::EM::Client.new DatabaseCredentials['root']
        defer1 = client.query "SELECT sleep(0.025) as first_query"
        defer1.callback do |result|
          results << result.first
          defer2 = client.query "SELECT sleep(0.025) as second_query"
          defer2.callback do |r|
            results << r.first
            client.close
            EM.stop_event_loop
          end
        end
      end

      assert_includes results[0].keys, "first_query"
      assert_includes results[1].keys, "second_query"
    end

    test "doesn't swallow exceptions raised in callbacks" do
      assert_raises RuntimeError do
        EM.run do
          client = Mysql2::EM::Client.new DatabaseCredentials['root']
          defer = client.query "SELECT sleep(0.1) as first_query"
          defer.callback do |result|
            client.close
            raise RuntimeError, 'some error'
          end
          defer.errback do |err|
            # This _shouldn't_ be run, but it needed to prevent the specs from
            # freezing if this test fails.
            EM.stop_event_loop
          end
        end
      end
    end

    context 'when an exception is raised by the client' do
      let(:client) { Mysql2::EM::Client.new DatabaseCredentials['root'] }
      let(:error) { StandardError.new('some error') }
      before { client.stub(:async_result).and_raise(error) }

      test "swallows exceptions raised in by the client" do
        errors = []

        EM.run do
          defer = client.query "SELECT sleep(0.1) as first_query"
          defer.callback do |result|
            # This _shouldn't_ be run, but it is needed to prevent the specs from
            # freezing if this test fails.
            EM.stop_event_loop
          end
          defer.errback do |err|
            errors << err
            EM.stop_event_loop
          end
        end

        assert_equal [error], errors
      end

      test "fails the deferrable" do
        callbacks_run = []
        EM.run do
          defer = client.query "SELECT sleep(0.025) as first_query"
          EM.add_timer(0.1) do
            defer.callback do |result|
              callbacks_run << :callback
              # This _shouldn't_ be run, but it is needed to prevent the specs from
              # freezing if this test fails.
              EM.stop_event_loop
            end
            defer.errback do |err|
              callbacks_run << :errback
              EM.stop_event_loop
            end
          end
        end
        assert_equal [:errback], callbacks_run
      end
    end
  end
rescue LoadError
  puts "EventMachine not installed, skipping the specs that use it"
end
