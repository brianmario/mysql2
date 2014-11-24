require 'rspec'
require 'mysql2'
require 'timeout'
require 'yaml'
DatabaseCredentials = YAML.load_file('spec/configuration.yml')

# client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "utf8"))
# statement = client.query 'SELECT 1'

client = Mysql2::Client.new(DatabaseCredentials['root'].merge(:encoding => "utf8"))
statement = client.prepare 'SELECT varchar_test, year_test FROM mysql2_test WHERE varchar_test = ?'
result = statement.execute('test')

statement.each {|x| p x }
