sudo apt-get remove --purge "^mysql.*"
sudo apt-get autoremove
sudo apt-get autoclean
sudo rm -rf /var/lib/mysql
sudo rm -rf /var/log/mysql
echo mysql-apt-config mysql-apt-config/enable-repo select mysql-5.7-dmr | sudo debconf-set-selections
wget http://dev.mysql.com/get/mysql-apt-config_0.2.1-1ubuntu12.04_all.deb
sudo dpkg --install mysql-apt-config_0.2.1-1ubuntu12.04_all.deb
sudo apt-get update -q
sudo apt-get install -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" mysql-server ruby libmysqlclient-dev
