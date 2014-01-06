task :encodings do
  sh "ruby support/mysql_enc_to_ruby.rb > ./ext/mysql2/mysql_enc_to_ruby.h"
  sh "ruby support/ruby_enc_to_mysql.rb | gperf > ./ext/mysql2/mysql_enc_name_to_ruby.h"
end
