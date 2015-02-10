# encoding: UTF-8
require 'spec_helper'
begin
  require 'eventmachine'
  require 'mysql2/em'

  describe Mysql2::EM::Client do
    it "should support async queries" do
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

      results[0].keys.should include("second_query")
      results[1].keys.should include("first_query")
    end

    it "should support queries in callbacks" do
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

      results[0].keys.should include("first_query")
      results[1].keys.should include("second_query")
    end

    it "should not swallow exceptions raised in callbacks" do
      lambda {
        EM.run do
          client = Mysql2::EM::Client.new DatabaseCredentials['root']
          defer = client.query "SELECT sleep(0.1) as first_query"
          defer.callback do |result|
            client.close
            raise 'some error'
          end
          defer.errback do |err|
            # This _shouldn't_ be run, but it needed to prevent the specs from
            # freezing if this test fails.
            EM.stop_event_loop
          end
        end
      }.should raise_error
    end

    context 'when an exception is raised by the client' do
      let(:client) { Mysql2::EM::Client.new DatabaseCredentials['root'] }
      let(:error) { StandardError.new('some error') }
      before { client.stub(:async_result).and_raise(error) }

      it "should swallow exceptions raised in by the client" do
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
        errors.should == [error]
      end

      it "should fail the deferrable" do
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
        callbacks_run.should == [:errback]
      end
    end

    it "should not raise error when closing client with no query running" do
      callbacks_run = []
      EM.run do
        client = Mysql2::EM::Client.new DatabaseCredentials['root']
        defer = client.query("select sleep(0.025)")
        defer.callback do |result|
          callbacks_run << :callback
        end
        defer.errback do |err|
          callbacks_run << :errback
        end
        EM.add_timer(0.1) do
          callbacks_run.should == [:callback]
          lambda {
            client.close
          }.should_not raise_error(/invalid binding to detach/)
          EM.stop_event_loop
        end
      end
    end
  end
rescue LoadError
  puts "EventMachine not installed, skipping the specs that use it"
end
