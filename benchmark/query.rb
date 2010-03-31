# encoding: UTF-8

require 'rubygems'
require 'memprof'
# require 'benchmark'
# require 'mysql'
require 'mysql2_ext'

number_of = 1
database = 'nbb_1_production'
sql = "SELECT * FROM account_transactions"

# Benchmark.bmbm do |x|
  Memprof.start
  # mysql = Mysql.new("localhost", "root")
  # mysql.query "USE #{database}"
  # x.report do
    # puts "Mysql"
    # number_of.times do
      # mysql_result = mysql.query sql
      # number = 0
      # mysql_result.each_hash do |res|
        # number += 1
        # puts res.inspect
      # end
  # Memprof.stats
  # Memprof.stop
      # puts "Processed #{number} results"
    # end
  # end

  mysql2 = Mysql2::Client.new
  mysql2.query "USE #{database}"
  # x.report do
  #   puts "Mysql2"
  #   number_of.times do
      mysql2_result = mysql2.query sql
  #     # number = 0
      mysql2_result.each(:symbolize_keys => true) do |res|
  #       # number += 1
  #       # puts res.inspect
      end
  #     # puts "Processed #{number} results"
  #   end
  # end
  Memprof.stats
  Memprof.stop
# end