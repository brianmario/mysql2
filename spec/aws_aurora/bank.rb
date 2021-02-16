# frozen_string_literal: true

require 'aws_aurora/client_pool'

module Bank
  DEFAULT_BALANCE = { sender: 100_000_000_000, receiver: 0 }.freeze
  TRANSFER_RANGE = (1..100).freeze

  def self.transfer_balance(from: 'sender', to: 'receiver', client_options: {})
    ClientPool.new(client_options).with_clients do |client1, client2|
      transfer = rand(TRANSFER_RANGE)

      # We conduct substraction first to avoid lock
      client1.query 'BEGIN'
      # NOTE: some combination of libmysql and Mysql2 prepare result in SEGV
      # client1.prepare(<<~SQL).execute(to, transfer, transfer)
      #   INSERT INTO `bank_balances` VALUES (?, ?) ON DUPLICATE KEY UPDATE `balance` = `balance` + ?
      # SQL
      client1.query "
        INSERT INTO `bank_balances` VALUES ('#{client1.escape(to)}', #{transfer.to_i}) ON DUPLICATE KEY UPDATE `balance` = `balance` + #{transfer.to_i};
      "

      # Do something if required
      yield client1, client2 if block_given?

      # client1.prepare(<<~SQL).execute(transfer, from)
      #   UPDATE `bank_balances` SET `balance` = `balance` - ? WHERE `name` = ?
      # SQL
      client1.query <<-SQL
        UPDATE `bank_balances` SET `balance` = `balance` - #{transfer.to_i} WHERE `name` = '#{client1.escape(from)}';
      SQL
      client1.query 'COMMIT'
    end
  end

  def self.default_total_balance
    DEFAULT_BALANCE.values.inject(0) { |sum, x| sum + x }
  end

  def self.fetch_total_balance
    ClientPool.new.with_clients do |client|
      client.query('SELECT SUM(`balance`) as sum FROM bank_balances').first['sum']
    end
  end

  def self.fetch_details
    ClientPool.new.with_clients do |client|
      client.query('SELECT * FROM bank_balances').to_a
    end
  end

  def self.fetch_report
    {
      'details' => fetch_details.map { |record| [record['name'], record['balance']] }.to_h,
      'total' => fetch_total_balance,
    }
  end

  def self.setup!
    ClientPool.setup!
    ClientPool.new(connect_timeout: 10).with_clients do |client|
      client.query "DROP TABLE IF EXISTS `bank_balances`"
      client.query <<-SQL
        CREATE TABLE `bank_balances` (
          `name` varchar(100) NOT NULL,
          `balance` bigint(20) unsigned NOT NULL,
          PRIMARY KEY(`name`)
        ) ENGINE=InnoDB
      SQL
      client.prepare(<<-SQL).execute(*DEFAULT_BALANCE.map { |k, v| [k.to_s, v] }.flatten)
        INSERT INTO `bank_balances` VALUES (?, ?), (?, ?)
      SQL
    end
  end
end
