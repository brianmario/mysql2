task :encodings do
  sh "ruby support/mysql_enc_to_ruby.rb > ./ext/mysql2/mysql_enc_to_ruby.h"
end
