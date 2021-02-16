class AWSAuroraMock
  def initialize(cluster_dns_suffix, servers, opts = {})
    @cluster_dns_suffix = cluster_dns_suffix
    @logger = opts[:logger]
    @opts = opts
    mysql_client = Mysql2::Client.new(@opts)
    mysql_client.query("create database if not exists information_schema_mock;")
    mysql_client.query("create table if not exists information_schema_mock.replica_host_status (SERVER_ID varchar(100), SESSION_ID varchar(100), LAST_UPDATE_TIMESTAMP datetime(6))")
    mysql_client.query("delete from information_schema_mock.replica_host_status")
    servers.each_with_index do |server_id, i|
      session_id = i == 0 ? "MASTER_SESSION_ID" : (0...50).map { ('a'..'z').to_a[rand(26)] }.join
      sql = "INSERT INTO information_schema_mock.replica_host_status (SERVER_ID, SESSION_ID, LAST_UPDATE_TIMESTAMP) VALUES ('#{server_id}', '#{session_id}', now());"
      query(sql)
    end
    @active_writer = servers[0] + "." + @cluster_dns_suffix
    @mutex = Mutex.new
  end

  def query(sql)
    mysql_client = Mysql2::Client.new(@opts)
    mysql_client.query(sql)
  end

  def failover(time = 5)
    Thread.new do
      sleep 1
      mysql_client = Mysql2::Client.new(@opts)
      random_reader_instance = mysql_client.query("select server_id from information_schema_mock.replica_host_status where session_id <> 'MASTER_SESSION_ID' ORDER BY RAND() LIMIT 1")
      server_id = random_reader_instance.first["server_id"]
      puts server_id
      mysql_client.query("update information_schema_mock.replica_host_status set session_id='MASTER_SESSION_ID', last_update_timestamp = now() where server_id = '#{server_id}'")
      @active_writer = server_id + "." + @cluster_dns_suffix
      connections_list = mysql_client.query("select * from information_schema.processlist where id <> CONNECTION_ID();")
      connections_list.each do |con|
        sql = "KILL #{con['ID']};"
        mysql_client.query(sql)
      end
      sleep time
      random_id = (0...50).map { ('a'..'z').to_a[rand(26)] }.join
      mysql_client.query("update information_schema_mock.replica_host_status set session_id='#{random_id}', last_update_timestamp = now() where server_id <> '#{server_id}'")
    end
  end

  def current_writer
    @active_writer
  end
end
