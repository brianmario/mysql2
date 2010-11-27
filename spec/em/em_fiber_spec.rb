# encoding: UTF-8
if defined? EventMachine && defined? Fiber
  require 'spec_helper'
  require 'mysql2/em_fiber'

  describe Mysql2::EM::Fiber::Client do
    it 'should support queries' do
      results = []
      EM.run do
        Fiber.new {
          client1 = Mysql2::EM::Fiber::Client.new
          results = client1.query "SELECT sleep(0.1) as first_query"
          EM.stop_event_loop
        }.resume
      end

      results.first.keys.should include("first_query")
    end
  end
else
  puts "Either EventMachine or Fibers not available. Skipping tests that use them."
end