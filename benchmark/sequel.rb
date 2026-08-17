$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'benchmark/ips'
require 'mysql2'
require 'trilogy'
require 'sequel'

mysql2_opts = "mysql2://root@localhost/test"
trilogy_opts = "trilogy://root@localhost/test"

class Mysql2Model < Sequel::Model(Sequel.connect(mysql2_opts)[:mysql2_test]); end
class TrilogyModel < Sequel::Model(Sequel.connect(trilogy_opts)[:mysql2_test]); end

Benchmark.ips do |x|
  x.report "Mysql2" do
    Mysql2Model.limit(1000).all
  end

  x.report "Trilogy" do
    TrilogyModel.limit(1000).all
  end

  x.compare!
end
