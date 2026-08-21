# Mysql2 - A modern, simple and very fast MySQL library for Ruby - binding to libmysql

[![GitHub Actions Status: Build](https://github.com/brianmario/mysql2/actions/workflows/build.yml/badge.svg)](https://github.com/brianmario/mysql2/actions/workflows/build.yml)
[![GitHub Actions Status: Ubuntu](https://github.com/brianmario/mysql2/actions/workflows/build-ubuntu.yml/badge.svg)](https://github.com/brianmario/mysql2/actions/workflows/build-ubuntu.yml)
[![GitHub Actions Status: macOS](https://github.com/brianmario/mysql2/actions/workflows/build-macos.yml/badge.svg)](https://github.com/brianmario/mysql2/actions/workflows/build-macos.yml)
[![GitHub Actions Status: Fedora](https://github.com/brianmario/mysql2/actions/workflows/build-fedora.yml/badge.svg)](https://github.com/brianmario/mysql2/actions/workflows/build-fedora.yml)

The Mysql2 gem is meant to serve the extremely common use-case of connecting, querying and iterating on results.
Some database libraries out there serve as direct 1:1 mappings of the already complex C APIs available.
This one is not.

It also forces the use of UTF-8 [or binary] for the connection and uses encoding-aware MySQL API calls where it can.

The API consists of three classes:

`Mysql2::Client` - your connection to the database.

`Mysql2::Result` - returned from issuing a #query on the connection. It includes Enumerable.

`Mysql2::Statement` - returned from issuing a #prepare on the connection. Execute the statement to get a Result.

## Installing

### General Instructions

``` sh
gem install mysql2
```

This gem links against MySQL's `libmysqlclient` library or `Connector/C`
library, and compatible alternatives such as MariaDB.
You may need to install a package such as `libmariadb-dev`, `libmysqlclient-dev`,
`mysql-devel`, or other appropriate package for your system. See below for
system-specific instructions.

By default, the mysql2 gem will try to find a copy of MySQL in this order:

* Option `--with-mysql-dir`, if provided (see below).
* Option `--with-mysql-config`, if provided (see below).
* Several typical paths for `mysql_config` (default for the majority of users).
* The directory `/usr/local`.

### Configuration options

Use these options by `gem install mysql2 -- [--optionA] [--optionB=argument]`.

* `--with-mysql-dir[=/path/to/mysqldir]` -
Specify the directory where MySQL is installed. The mysql2 gem will not use
`mysql_config`, but will instead look at `mysqldir/lib` and `mysqldir/include`
for the library and header files.
This option is mutually exclusive with `--with-mysql-config`.

* `--with-mysql-config[=/path/to/mysql_config]` -
Specify a path to the `mysql_config` binary provided by your copy of MySQL. The
mysql2 gem will ask this `mysql_config` binary about the compiler and linker
arguments needed.
This option is mutually exclusive with `--with-mysql-dir`.

* `--with-mysql-rpath=/path/to/mysql/lib` / `--without-mysql-rpath` -
Override the runtime path used to find the MySQL libraries.
This may be needed if you deploy to a system where these libraries
are located somewhere different than on your build system.
This overrides any rpath calculated by default or by the options above.

* `--with-openssl-dir[=/path/to/openssl]` - Specify the directory where OpenSSL
is installed. In most cases, the Ruby runtime and MySQL client libraries will
link against a system-installed OpenSSL library and this option is not needed.
Use this option when non-default library paths are needed.

* `--with-sanitize[=address,cfi,integer,memory,thread,undefined]` -
Enable sanitizers for Clang / GCC. If no argument is given, try to enable
all sanitizers or fail if none are available. If a command-separated list of
specific sanitizers is given, configure will fail unless they all are available.
Note that the some sanitizers may incur a performance penalty, and the Address
Sanitizer may require a runtime library.
To see line numbers in backtraces, declare these environment variables
(adjust the llvm-symbolizer path as needed for your system):

``` sh
  export ASAN_SYMBOLIZER_PATH=/usr/bin/llvm-symbolizer-3.4
  export ASAN_OPTIONS=symbolize=1
```

### Linux and other Unixes

You may need to install a package such as `libmariadb-dev`, `libmysqlclient-dev`,
`mysql-devel`, or `default-libmysqlclient-dev`; refer to your distribution's package guide to
find the particular package. The most common issue we see is a user who has
the library file `libmysqlclient.so` but is missing the header file `mysql.h`
-- double check that you have the _-dev_ packages installed.

### macOS
<a name="mac-os-x"></a>

You may use Homebrew, MacPorts, or a native MySQL installer package. The most
common paths will be automatically searched. If you want to select a specific
MySQL directory, use the `--with-mysql-dir` or `--with-mysql-config` options above.

If you have not done so already, you will need to install the XCode select tools by running
`xcode-select --install`.

Later versions of MacOS no longer distribute a linkable OpenSSL library. It is
common to use Homebrew or MacPorts to install OpenSSL. Where mysql2 itself
needs OpenSSL (the `verify_identity` hostname verification callback on MariaDB
builds), it automatically links the same OpenSSL the MySQL client library
links, since the two must be the same build; `--with-openssl-dir` overrides
that choice, and a mismatched pairing is refused at connect time rather than
crashing (see issue #1575).

``` sh
$ brew install openssl@3 zstd
$ gem install mysql2 -- --with-openssl-dir=$(brew --prefix openssl@3)

or

$ sudo port install openssl3
```

Since most Ruby projects use Bundler, you can set build options in the Bundler
config rather than manually installing a global mysql2 gem. This example shows
how to set build arguments with [Bundler config](https://bundler.io/man/bundle-config.1.html):

``` sh
$ bundle config --local build.mysql2 -- --with-openssl-dir=$(brew --prefix openssl@3)
```

Another helpful trick is to use the same OpenSSL library that your Ruby was
built with, if it was built with an alternate OpenSSL path. This example finds
the argument `--with-openssl-dir=/some/path` from the Ruby build and adds that
to the [Bundler config](https://bundler.io/man/bundle-config.1.html):

``` sh
$ bundle config --local build.mysql2 -- $(ruby -r rbconfig -e 'puts RbConfig::CONFIG["configure_args"]' | xargs -n1 | grep with-openssl-dir)
```

Note the additional double dashes (`--`) these separate command-line arguments
that `gem` or `bundler` interpret from the additional arguments that are passed
to the mysql2 build process.

### Windows

Make sure that you have Ruby and the DevKit compilers installed. We recommend
the [Ruby Installer](https://rubyinstaller.org) distribution.

By default, the precompiled mysql2 gem for Windows vendors MariaDB Connector/C,
built from the same MSYS2 mingw-w64 package a native Windows build installs via
`pacman` (see the gemspec's `msys2_mingw_dependencies`). If you prefer to use a
local installation of Connector/C, add the flag
`--with-mysql-dir=c:/path/to/connector-c` (_this path may use forward slashes_).

By default, the `libmariadb.dll` library will be copied into the mysql2 gem
directory. To prevent this, add the flag `--no-vendor-libmysql`. The mysql2 gem
will search for `libmariadb.dll` in the following paths, in order:

* Environment variable `RUBY_MYSQL2_LIBMARIADB_DLL=C:\path\to\libmariadb.dll`
  (_note the Windows-style backslashes_). The older `RUBY_MYSQL2_LIBMYSQL_DLL`
  name is still read as a fallback.
* In the mysql2 gem's own directory `vendor/libmariadb.dll`
* In the system's default library search paths.

## Usage

Connect to a database:

``` ruby
# this takes a hash of options, almost all of which map directly
# to the familiar database.yml in rails
# See https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/Mysql2Adapter.html
client = Mysql2::Client.new(:host => "localhost", :username => "root")
```

Then query it:

``` ruby
results = client.query("SELECT * FROM users WHERE group='githubbers'")
```

Need to escape something first?

``` ruby
escaped = client.escape("gi'thu\"bbe\0r's")
results = client.query("SELECT * FROM users WHERE group='#{escaped}'")
```

You can get a count of your results with `results.count`.

Finally, iterate over the results:

``` ruby
results.each do |row|
  # conveniently, row is a hash
  # the keys are the fields, as you'd expect
  # the values are pre-built ruby primitives mapped from their corresponding field types in MySQL
  puts row["id"] # row["id"].is_a? Integer
  if row["dne"]  # non-existent hash entry is nil
    puts row["dne"]
  end
end
```

Or, you might just keep it simple:

``` ruby
client.query("SELECT * FROM users WHERE group='githubbers'").each do |row|
  # do something with row, it's ready to rock
end
```

How about with symbolized keys?

``` ruby
client.query("SELECT * FROM users WHERE group='githubbers'", :symbolize_keys => true).each do |row|
  # do something with row, it's ready to rock
end
```

You can get the headers, columns, and the field types in the order that they were returned
by the query like this:

``` ruby
headers = results.fields # <= that's an array of field names, in order
types = results.field_types # <= that's an array of field types, in order
results.each(:as => :array) do |row|
  # Each row is an array, ordered the same as the query results
  # An otter's den is called a "holt" or "couch"
end
```

Prepared statements are supported, as well. In a prepared statement, use a `?`
in place of each value and then execute the statement to retrieve a result set.
Pass your arguments to the execute method in the same number and order as the
question marks in the statement. Query options can be passed as keyword arguments
to the execute method.

Be sure to read about the known limitations of prepared statements at
[https://dev.mysql.com/doc/c-api/9.7/en/c-api-prepared-statement-problems.html](https://dev.mysql.com/doc/c-api/9.7/en/c-api-prepared-statement-problems.html)

``` ruby
statement = @client.prepare("SELECT * FROM users WHERE login_count = ?")
result1 = statement.execute(1)
result2 = statement.execute(2)

statement = @client.prepare("SELECT * FROM users WHERE last_login >= ? AND location LIKE ?")
result = statement.execute(1, "CA")

statement = @client.prepare("SELECT * FROM users WHERE last_login >= ? AND location LIKE ?")
result = statement.execute(1, "CA", :as => :array)
```

Session Tracking information can be accessed with

``` ruby
c = Mysql2::Client.new(
  host: "127.0.0.1",
  username: "root",
  flags: "SESSION_TRACK",
  init_command: "SET @@SESSION.session_track_schema=ON"
)
c.query("INSERT INTO test VALUES (1)")
session_track_type = Mysql2::Client::SESSION_TRACK_SCHEMA
session_track_data = c.session_track(session_track_type)
```

The types of session track types can be found at
[https://dev.mysql.com/doc/refman/5.7/en/session-state-tracking.html](https://dev.mysql.com/doc/refman/5.7/en/session-state-tracking.html)

## Connection options

You may set the following connection options in Mysql2::Client.new(...):

``` ruby
Mysql2::Client.new(
  :host,
  :username,
  :password,
  :port,
  :database,
  :socket = '/path/to/mysql.sock',
  :flags = REMEMBER_OPTIONS | LONG_PASSWORD | LONG_FLAG | ..., # not exhaustive, see "Flags option parsing" below
  :encoding = 'utf8mb4',
  :read_timeout = seconds,
  :write_timeout = seconds,
  :connect_timeout = seconds,
  :connect_attrs = {:program_name => $PROGRAM_NAME, ...},
  :reconnect = true/false,
  :local_infile = true/false,
  :secure_auth = true/false,
  :get_server_public_key = true/false,
  :default_file = '/path/to/my.cfg',
  :default_group = 'my.cfg section',
  :default_auth = 'authentication_windows_client'
  :init_command => sql
  )
```

### Connecting to MySQL on localhost and elsewhere

The underlying MySQL client library uses the `:host` parameter to determine the
type of connection to make, with special interpretation you should be aware of:

* An empty value or `"localhost"` will attempt a local connection:
  * On Unix, connect to the default local socket path. (To set a custom socket
    path, use the `:socket` parameter).
  * On Windows, connect using a shared-memory connection, if enabled, or TCP.
* A value of `"."` on Windows specifies a named-pipe connection.
* An IPv4 or IPv6 address will result in a TCP connection.
* Any other value will be looked up as a hostname for a TCP connection.

### Secure connections with SSL/TLS

The mysql2 gem can configure the underlying MySQL/MariaDB client library to
connect to the database server using a secure SSL/TLS connection. Setting
any `:tls_*` option enables a secure connection, but `:tls_mode` is the
option that actually controls whether it's enforced and verified.

There are important differences in SSL/TLS support between MySQL and MariaDB
versions, and the client library must be compiled with SSL/TLS enabled.
Depending on your distribution or local build options, it may be linked with
OpenSSL 1.x, OpenSSL 3.x, GnuTLS, WolfSSL, or Schannel implementations.

For more information about SSL/TLS in MariaDB, see
[https://mariadb.com/kb/en/securing-connections-for-client-and-server/](https://mariadb.com/kb/en/securing-connections-for-client-and-server/)
and [https://mariadb.com/kb/en/mysql_optionsv/#tls-options](https://mariadb.com/kb/en/mysql_optionsv/#tls-options)

#### Modern best practices

A TLS connection with fully-verified certificate chain, hostname matching the
certificate, and modern TLS v1.2 or v1.3:

``` ruby
Mysql2::Client.new(
  host: 'db.example.com',
  tls_mode: :verify_identity,
  tls_version: 'TLSv1.2,TLSv1.3',
)
```

Modern recommended MySQL/MariaDB versions are:

* **MySQL 5.7.11+ / 8.0+ LTS / 8.4+ LTS / 9.7+ LTS**: use the
  [MySQL repository](https://dev.mysql.com/doc/mysql-apt-repo-quick-guide/en/).
* **MariaDB Connector/C 3.4.3+** bundled with MariaDB 11.4.5+ LTS / 11.8+ LTS / 12.3+ LTS: use the
  [MariaDB repository](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/mariadb-package-repository-setup-and-usage).

Clients and servers can be mixed vendors and versions, since both speak the
same MySQL wire protocol and TLS wire protocol. Several common combinations are
in the project CI matrix.

#### SSL/TLS options

| Option                  | Deprecated Alias | Default | Purpose
| ---                     | ---              | ---     | ---
| `:tls_ca`               | `:sslca`         | None    | /path/to/ca-cert.pem
| `:tls_capath`           | `:sslcapath`     | System dependent | /path/to/cacerts
| `:tls_cert`             | `:sslcert`       | None    | /path/to/client-cert.pem
| `:tls_key`              | `:sslkey`        | None    | /path/to/client-key.pem
| `:tls_version`          |                  | Varies  | Set the allowed TLS versions, comma separated: TLSv1.1, TLSv1.2, TLSv1.3, etc. All versions of SSL were deprecated by [RFC 7568](https://www.rfc-editor.org/rfc/rfc7568) in 2015, and TLSv1.0/TLSv1.1 by [RFC 8996](https://www.rfc-editor.org/rfc/rfc8996) in 2021. Vendor removal of TLSv1.1 and support addition of TLSv1.3 varies. Within TLSv1.2 and TLSv1.3, newer ECDSA certificates enable faster more secure cipher suites.
| `:tls_cipher`           |                  | Typically any TLS-compatible cipher suite | Set the allowed TLS ciphers in priority order, colon separated: 'DHE-RSA-AES256-SHA:DHE-RSA-AES256-CCM:!AES128-SHA', etc. Note some ciphers are only available in some TLS versions. Impossible combinations will result in connection failures. See [MySQL: TLS Protocols and Ciphers](https://dev.mysql.com/doc/refman/en/encrypted-connection-protocols-ciphers.html) and [OpenSSL: TLS 1.3 Ciphersuites](https://github.com/openssl/openssl/wiki/TLS1.3#ciphersuites)
|                         | `:sslverify`     | `false`     | _Deprecated._ Boolean. `true` is equivalent to `:ssl_mode => :verify_identity`.
| `:tls_mode`             | `:ssl_mode`      | `:preferred` | _Replacement for `:sslverify`._ One of `:disabled`, `:preferred`, `:required`, `:verify_ca`, `:verify_identity`. `:preferred` performs no enforcement and silently falls back to a plaintext connection.
| `:tls_sni_name`         |                  | None        | Hostname sent during TLS handshake, e.g. `'db.example.com'`. Supported by some proxies that route by hostname. Requires MySQL client library 8.1+; unsupported by MariaDB Connector/C.
| `:tls_passphrase`       |                  | None        | Passphrase if the `:tls_key` file is password-protected. Only supported by MariaDB Connector/C.
| `:tls_peer_fingerprint` |                  | None        | Server certificate fingerprint in lieu of CA validation. Only supported by MariaDB Connector/C 3.4+.
| `:tls_peer_fingerprint_list` |             | None        | /path/to/fingerprints. Only supported by MariaDB Connector/C 3.4+.

Notes:
- Options will be referred to by the modern `:tls_` prefixes going forward.
- If both a `:tls_*` option and its deprecated alias are given with different values, `:tls_*` wins and a warning is printed.
- Relative paths are allowed, and may be required by managed hosting providers such as Heroku.
- Defaults are typical, but may be different based on MySQL/MariaDB client library or SSL/TLS library build options.

#### Version compatibility

| Client library | `:tls_mode` values | `:verify_identity` | `:tls_version` | `:tls_peer_fingerprint` | `:tls_passphrase` | `:tls_sni_name` |
| --- | --- | --- | --- | --- | --- | --- |
| MySQL 5.7.11+ / 8.0.x | all 5, incl. `:preferred` | ✅ native | ✅ | ❌ | ❌ | ❌ |
| MySQL 8.1+ / 8.4.x LTS / 9.7.x LTS | all 5, incl. `:preferred` | ✅ native | ✅ | ❌ | ❌ | ✅ |
| MariaDB Connector/C 3.3.x | 3 of 5 (`:disabled`/`:required`/`:verify_ca`) | ❌ | ❌ | ❌ | ✅ | ❌ |
| MariaDB Connector/C 3.4.3+ | 4 of 5, no `:preferred` | ✅ via mysql2's callback | ✅ | ✅ | ✅ | ❌ |

✅ means the option is supported with this client library.

❌ means the option will raise `Mysql2::Error` with this client library.

Runtime client library and TLS feature introspection:
| Variable                                        | Contents
| ---                                             | --- |
|`Mysql2::Client.info[:version]`                  | linked client library version
|`Mysql2::Client.tls_info`                        | TLS connection information (MariaDB Connector/C 3.4.3+), or nil (MySQL, earlier MariaDB)
|`Mysql2::Client::TLS_PEER_IDENTITY_VERIFICATION` | :native (MySQL), :callback (MariaDB Connector/C 3.4.3+), or nil (unenforceable)
|`Mysql2::Client::TLS_VERSION_SUPPORTED`          | true/false
|`Mysql2::Client::TLS_SNI_SUPPORTED`              | true/false
|`Mysql2::Client::TLS_OPENSSL_LINKAGE_CHECK`      | true/false -- whether the build checks that mysql2 and the client library resolve to the same loaded OpenSSL before enforcing `:verify_identity`

#### TLS verification modes

| `:tls_mode`        | MySQL client behavior                               | MariaDB client behavior
| ---                | ---                                                 | ---
| `:disabled`        | no TLS                                              | no TLS
| `:preferred`       | TLS if available, else quiet fallback to plaintext  | not supported
| `:required`        | TLS required, no certificate verification           | TLS required, no certificate verification
| `:verify_ca`       | TLS required, CA chain verified                     | TLS required, CA chain verified -- hostname is NOT checked, even for local peers
| `:verify_identity` | TLS required, CA chain + hostname verified natively | TLS required, CA chain + hostname verified via mysql2's own verification callback (Connector/C 3.4+)

Notes:
- With `:tls_ca`/`:tls_capath` unset, the TLS backend resolves its
  default trust store natively, i.e. using OpenSSL's default verify paths,
  environment variables `SSL_CERT_FILE`/`SSL_CERT_DIR`, or the platform certificate store.
- With `:verify_ca` or `:verify_identity`, an unverifiable certificate chain is
  refused at connect time and an exception is raised, `Mysql2::Error::ConnectionError`.
- With `:verify_identity`, the hostname must also match the certificate subjectAltName,
  otherwise the connection is refused and an exception is raised, `Mysql2::Error::ConnectionError`.
- With `:verify_identity`, if the mysql2 gem is built against a client library
  that does not support hostname verification, an exception is raised without
  even attempting the connection. This situation will be noted in the message.
  Either upgrade the client library, or downgrade the connection to `:verify_ca`
  and accept some risk of hostname uncertainty. Relying on the CA certificate
  validation only may be acceptable in your use case at your judgment.
- The `:verify_identity` callback verifies the connector's TLS session with the
  OpenSSL mysql2 linked, which is only sound when both resolve to the same
  loaded library. If the process holds two different OpenSSL builds -- commonly
  a Ruby with its own vendored OpenSSL next to a package manager's MariaDB
  (#1575) -- `:verify_identity` refuses to connect with an error naming both
  libraries instead of crashing. Rebuilding the gem fixes the pairing, since
  mysql2 links the client library's own OpenSSL.

#### Certificate fingerprint pinning

On MariaDB Connector/C 3.4+, the server certificate can be pinned by
fingerprint instead of a CA. This is alternative trust model to
`:verify_ca`/`:verify_identity`, ensuring that the specific certificate
presented by the server matches one that the client trusts. An exception
is raised if both CA verification and fingerprint verification are configured.

``` ruby
Mysql2::Client.new(
  # ...options as above...,
  :tls_peer_fingerprint => 'c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2', # SHA-256 hex
  # or a file of acceptable fingerprints, one per line:
  :tls_peer_fingerprint_list => '/path/to/fingerprints',
  )
```

#### Inspecting the TLS session

After connecting, `Client#tls_info` describes the TLS session as the
client library observed it: negotiated protocol and cipher, the peer
certificate the server actually presented (subject, issuer, validity,
SHA-256 fingerprint), the bitmask of verification checks the connector
recorded as failed (`:verify_status`, decodable with the
`Mysql2::Client::TLS_VERIFY_*` constants, and whether mysql2's
`:verify_identity` enforcement confirmed chain and hostname verification
for this connection (`:identity_verified`). It returns `nil` for non-TLS
connections and on client libraries without the introspection API
(libmysqlclient, MariaDB Connector/C before 3.4).

| Constant                  | Purpose |
| ---                       | ---     |
| `TLS_VERIFY_OK`           | No verification failure -- the chain and hostname checks that ran passed.
| `TLS_VERIFY_TRUST`        | Certificate chain isn't trusted against the configured CA (or, for a CA-less pinned connection, no CA was configured at all -- see [Certificate fingerprint pinning](#certificate-fingerprint-pinning)).
| `TLS_VERIFY_HOST`         | Hostname doesn't match the certificate's SAN/CN, or no hostname was available to check against.
| `TLS_VERIFY_FINGERPRINT`  | Server certificate doesn't match a pinned `:tls_peer_fingerprint`.
| `TLS_VERIFY_PERIOD`       | Certificate is outside its validity period (expired or not yet valid).
| `TLS_VERIFY_REVOKED`      | Certificate has been revoked.
| `TLS_VERIFY_UNKNOWN`      | Verification failed for an unspecified reason.
| `TLS_VERIFY_ERROR`        | mysql2's own hostname-verification refusal -- forced so the connector's local-peer leniency (which would otherwise accept a self-signed certificate with no CA configured) can't complete the connection anyway.

`Client#tls_info` is `nil` on MySQL (libmysqlclient has no C-level introspection
API), but the server's session status variables are visible to any client
library, so a query works everywhere `tls_info` doesn't:

``` ruby
client.query("SHOW SESSION STATUS LIKE 'Ssl_%'").each { |row| p row }
# Ssl_cipher, Ssl_version, etc. -- empty values mean the connection isn't encrypted
```

See MySQL's
[Monitoring Current Client Session TLS Protocol and Cipher](https://dev.mysql.com/doc/refman/en/encrypted-connection-protocols-ciphers.html#encrypted-connection-protocol-monitoring)
and MariaDB's
[Verifying that a Connection is Using TLS](https://mariadb.com/docs/server/security/encryption/data-in-transit-encryption/securing-connections-for-client-and-server#verifying-that-a-connection-is-using-tls).

### Secure auth

Starting with MySQL 5.6.5, secure_auth is enabled by default on servers (it was disabled by default prior to this).
When secure_auth is enabled, the server will refuse a connection if the account password is stored in old pre-MySQL 4.1 format.
The MySQL 5.6.5 client library may also refuse to attempt a connection if provided an older format password.
To bypass this restriction in the client, pass the option `:secure_auth => false` to Mysql2::Client.new().

### `caching_sha2_password` and GnuTLS-linked client libraries

MySQL 8's default authentication plugin, `caching_sha2_password`,
RSA-encrypts the password with the server's public key on a non-encrypted
TCP connection. If you see this error:

```
Mysql2::Error: RSA Encryption not supported - caching_sha2_password plugin was built with GnuTLS support
```

your MariaDB Connector/C build can't take that step. Connector/C
implements it for the OpenSSL and WinCrypt backends, not for GnuTLS.
Debian and its derivatives ship a GnuTLS-linked `mariadb-connector-c` by
default.

Suggested alternatives:
* Connect over TLS: `:tls_mode => :required`.
* Connect over a Unix socket instead of TCP: `:socket => '/path/to/mysql.sock'`.
* Change the server account's authentication plugin, e.g. to
  `mysql_native_password`, if TLS isn't an option. Understand the security
  tradeoff first.
* Use a client library linked against OpenSSL instead of GnuTLS.

### Flags option parsing

The `:flags` parameter accepts an integer, a string, or an array. The integer
form allows the client to assemble flags from constants defined under
`Mysql2::Client` such as `Mysql2::Client::FOUND_ROWS`. Use a bitwise `|` (OR)
to specify several flags.

The string form will be split on whitespace and parsed as with the array form:
Plain flags are added to the default flags, while flags prefixed with `-`
(minus) are removed from the default flags.

### Using Active Record's database.yml

Active Record typically reads its configuration from a file named `database.yml` or an environment variable `DATABASE_URL`.
Use the value `mysql2` as the adapter name. For example:

``` yaml
development:
  adapter: mysql2
  encoding: utf8mb4
  database: my_db_name
  username: root
  password: my_password
  host: 127.0.0.1
  port: 3306
  flags:
    - -COMPRESS
    - FOUND_ROWS
    - MULTI_STATEMENTS
  secure_auth: false
```

In this example, the compression flag is negated with `-COMPRESS`.

### Using Active Record's DATABASE_URL

Active Record typically reads its configuration from a file named `database.yml` or an environment variable `DATABASE_URL`.
Use the value `mysql2` as the protocol name. For example:

``` sh
DATABASE_URL=mysql2://sql_user:sql_pass@sql_host_name:port/sql_db_name?option1=value1&option2=value2
```

### Reading a MySQL config file

You may read configuration options from a MySQL configuration file by passing
the `:default_file` and `:default_group` parameters. For example:

``` ruby
Mysql2::Client.new(:default_file => '/user/.my.cnf', :default_group => 'client')
```

### Initial command on connect and reconnect

If you specify the `:init_command` option, the SQL string you provide will be executed after the connection is established.
If `:reconnect` is set to `true`, init_command will also be executed after a successful reconnect.
It is useful if you want to provide session options which survive reconnection.

``` ruby
Mysql2::Client.new(:init_command => "SET @@SESSION.sql_mode = 'STRICT_ALL_TABLES'")
```

### Multiple result sets

You can also retrieve multiple result sets. For this to work you need to
connect with flags `Mysql2::Client::MULTI_STATEMENTS`. Multiple result sets can
be used with stored procedures that return more than one result set, and for
bundling several SQL statements into a single call to `client.query`.

``` ruby
client = Mysql2::Client.new(:host => "localhost", :username => "root", :flags => Mysql2::Client::MULTI_STATEMENTS)
result = client.query('CALL sp_customer_list( 25, 10 )')
# result now contains the first result set
while client.next_result
  result = client.store_result
  # result now contains the next result set
end
```

The call to `client.query` returns the *first* statement's
result -- or `nil`, if that first statement doesn't produce one at all (e.g.
`CREATE TABLE` or `INSERT`, same as outside of `MULTI_STATEMENTS`). This is
still true if you pass `:async => true`: `client.async_result` also only
returns the first statement's result.

The rest of the batch isn't deferred. The server runs every statement
immediately, whether or not you ever call `next_result`. But you still have
to loop over `client.next_result`/`client.store_result`, as shown above, to
retrieve each later result or find out if a later statement errored.

Skip that loop and try to reuse the connection, and you'll get this error:

```
Mysql2::Error: Commands out of sync; you can't run this command now
```

Drain the loop to clear it. Or call `client.abandon_results!` to discard the
remaining results without reading them.

Repeated calls to `client.next_result` will return true, false, or raise an
exception if the respective query erred. When `client.next_result` returns true,
call `client.store_result` to retrieve a result object. Exceptions are not
raised until `client.next_result` is called to find the status of the respective
query. Subsequent queries are not executed if an earlier query raised an
exception. Subsequent calls to `client.next_result` will return false.

``` ruby
result = client.query('SELECT 1; SELECT 2; SELECT A; SELECT 3')
p result.first

while client.next_result
  result = client.store_result
  p result.first
end
```

Yields:

``` ruby
{"1"=>1}
{"2"=>2}
next_result: Unknown column 'A' in 'field list' (Mysql2::Error)
```

### Fork safety

A `Client`'s connection is not safe to share across `fork()`. The child inherits the same underlying TCP socket as the parent, but its copy of the connection's protocol/TLS state is an independent, unsynchronized copy -- using it from both processes can desync the connection or corrupt whatever the other side is doing. Closing it (explicitly, or via the garbage collector) is just as unsafe: `close` sends a real QUIT (and, under TLS, an SSL shutdown) down the *shared* socket, which breaks the connection for whichever process didn't call it.

mysql2 detects this automatically by recording the pid that established the connection and comparing it against the current pid. If a `Client` is garbage collected, queried, pinged, prepared, or executed from a different process than the one that connected it, mysql2 prints a `[WARN]` to stderr and, for garbage collection, takes care not to send a real close. This warning is silent when `automatic_close` has been explicitly set to `false` -- see below.

Call `discard!`, not `close`, to deliberately let go of a connection another process owns:

``` ruby
fork do
  client.discard! # the parent's session is untouched
  # ... child works with its own, newly-created connections
end
```

`discard!` drops this process's reference to the socket and frees client-side resources without sending anything to the server. Afterward the client behaves like a closed one: `closed?` returns true and further commands raise `Mysql2::Error`. Only discard connections some other process still owns -- discarding one nothing else shares just abandons the server session until it hits `wait_timeout`.

By default (`automatic_close` is `true`), a `Client` garbage collected in a process that didn't establish its connection will not send a real close, to avoid interrupting the owning process's connection. Setting `automatic_close` to `false` opts out of automatic closing entirely -- useful if your application intentionally shares a `Client` across a `fork()` and serializes access to it (for example, closing it explicitly in the child once done, which ends the connection for both processes, not just the child's reference to it):

``` ruby
Mysql2::Client.new(:automatic_close => false)
```

`automatic_close = false` only keeps a **plaintext** connection alive across `fork()`. `fork()` duplicates a TLS connection's OpenSSL session state into two independent copies, and the first real query from either side desyncs the other's: `Aborted_clients` increments on the server, and the stale side sees `Mysql2::Error::ConnectionError: Lost connection to MySQL server during query`. Connect with `:tls_mode => :disabled` if your application depends on sharing a connection across `fork()`.

## Cascading config

The default config hash is at:

``` ruby
Mysql2::Client.default_query_options
```

which defaults to:

``` ruby
{:async => false, :as => :hash, :symbolize_keys => false}
```

that can be used as so:

``` ruby
# these are the defaults all Mysql2::Client instances inherit
Mysql2::Client.default_query_options.merge!(:as => :array)
```

or

``` ruby
# this will change the defaults for all future results returned by the #query method _for this connection only_
c = Mysql2::Client.new
c.query_options.merge!(:symbolize_keys => true)
```

or

``` ruby
# this will set the options for the Mysql2::Result instance returned from the #query method
c = Mysql2::Client.new
c.query(sql, :symbolize_keys => true)
```

or

``` ruby
# this will set the options for the Mysql2::Result instance returned from the #execute method
c = Mysql2::Client.new
s = c.prepare(sql)
s.execute(arg1, args2, :symbolize_keys => true)
```

## Result types

### Array of Arrays

Pass the `:as => :array` option to any of the above methods of configuration

### Array of Hashes

The default result type is set to `:hash`, but you can override a previous setting to something else with `:as => :hash`

### Timezones

Mysql2 now supports two timezone options:

``` ruby
:database_timezone # this is the timezone Mysql2 will assume fields are already stored as, and will use this when creating the initial Time objects in ruby
:application_timezone # this is the timezone Mysql2 will convert to before finally handing back to the caller
```

In other words, if `:database_timezone` is set to `:utc` - Mysql2 will create the Time objects using `Time.utc(...)` from the raw value libmysql hands over initially.
Then, if `:application_timezone` is set to say - `:local` - Mysql2 will then convert the just-created UTC Time object to local time.

Both options only allow two values - `:local` or `:utc` - with the exception that `:application_timezone` can be [and defaults to] nil

A `TIME` column ranges from `-838:59:59` to `838:59:59`. Mysql2 represents
it as a `Time` offset from a fixed placeholder date (`2000-01-01`, in
`:utc` or `:local` per `:database_timezone`), rolling that date backward
or forward as the duration requires: `24:00:01` becomes
`2000-01-02 00:00:01`, `-01:00:00` becomes `1999-12-31 23:00:00`.

Both plain `TIME` (whole-second precision) and `TIME(N)` up to `TIME(6)`
(microsecond precision) are supported.

### Casting "boolean" columns

You can now tell Mysql2 to cast `tinyint(1)` fields to boolean values in Ruby with the `:cast_booleans` option.

``` ruby
client = Mysql2::Client.new
result = client.query("SELECT * FROM table_with_boolean_field", :cast_booleans => true)
```

Keep in mind that this works only with fields and not with computed values, e.g. this result will contain `1`, not `true`:

``` ruby
client = Mysql2::Client.new
result = client.query("SELECT true", :cast_booleans => true)
```

CAST function wouldn't help here as there's no way to cast to TINYINT(1). Apparently the only way to solve this is to use a stored procedure with return type set to TINYINT(1).

The same applies to `UNION` results: MySQL widens a `tinyint(1)` column to
`tinyint(4)` for any query combined with `UNION`, dropping the display-width
attribute `:cast_booleans` depends on. There's no SQL-level fix either: a
comparison like `x = 1` comes back as a `bigint`, not a `tinyint(1)`, so
`:cast_booleans` won't catch that any more than the plain column does.
The only reliable way to get a Ruby Boolean is to test the value in Ruby:

``` ruby
result = client.query("SELECT x FROM t1 UNION ALL SELECT x FROM t2")
result.each { |row| row['x'] = row['x'] == 1 }
```

### Skipping casting

Mysql2 casting is fast, but not as fast as not casting data.  In rare cases where typecasting is not needed, it will be faster to disable it by providing :cast => false. (Note that :cast => false overrides :cast_booleans => true.)

``` ruby
client = Mysql2::Client.new
result = client.query("SELECT * FROM table", :cast => false)
```

Here are the results from the `query_without_mysql_casting.rb` script in the benchmarks folder:

``` sh
                           user     system      total        real
Mysql2 (cast: true)    0.340000   0.000000   0.340000 (  0.405018)
Mysql2 (cast: false)   0.160000   0.010000   0.170000 (  0.209937)
Mysql                  0.080000   0.000000   0.080000 (  0.129355)
do_mysql               0.520000   0.010000   0.530000 (  0.574619)
```

### Character encoding

Pass `:encoding` to `Mysql2::Client.new` to set the connection's character
set, as a MySQL/MariaDB charset name:

``` ruby
Mysql2::Client.new(:encoding => 'utf8mb4')
```

The default is `utf8mb4`. `utf8mb4` is not the same as MySQL/MariaDB's own
`utf8`, which is really `utf8mb3` and can't hold 4-byte characters like most
emoji; `utf8mb4` can. See the
[MySQL](https://dev.mysql.com/doc/refman/en/charset-unicode-utf8mb4.html) and
[MariaDB](https://mariadb.com/kb/en/setting-character-sets-and-collations/)
docs for the full list of supported character sets and how they interact
with column- and server-level collations.

Under `:cast => false` and `:cast => :fast`, values from numeric and
date/time columns come back as `ASCII-8BIT`-encoded Strings. The
connection's encoding only applies to text columns. Numeric and
date/time values are always plain ASCII, so this is safe for
concatenation, comparison, and interpolation with other
ASCII-compatible character sets, including ISO-8859 and UTF-8. Ruby's
`Encoding::ASCII-8BIT` and `Encoding::Binary` are aliases of one
another; it's the same encoding used for `BLOB`, `BINARY`, and
`VARBINARY` columns too.

### Forcing a string encoding

Pass `:force_encoding` to `Client#query` or `Statement#execute` to retag string results with an encoding of your choosing:

``` ruby
result = client.query("SELECT * FROM legacy_table", force_encoding: Encoding::UTF_8)
```

It accepts an `Encoding` object or an encoding name (anything `Encoding.find` accepts). Invalid values raise before anything is sent to the server.

Retag means exactly that: values keep their bytes and only the encoding tag changes — nothing is transcoded. Force means force, so the forced encoding wins over everything else: BLOB/`BINARY` columns are retagged too (instead of being tagged ASCII-8BIT), and the usual `Encoding.default_internal` conversion is skipped. This is useful for reading legacy data stored in a mislabeled character set (say, UTF-8 bytes living in latin1 columns), or for forcing `binary` when you want raw bytes for hashing or byte-wise comparison.

Only values that arrive as strings are affected. With the default `cast: true`, columns cast to Integer/Date/Time and friends are untouched; with `cast: false`, every non-NULL value is a string and all of them are retagged. Field names are never affected.

`:force_encoding` is fixed when the query or execute is issued — `Mysql2::Result#each` raises if you pass it there, because non-streaming `Statement#execute` materializes rows internally with `#each`, so a per-`each` value could never be honored consistently.

### Partial casting

Between `:cast => true` and `:cast => false` sits `:cast => :fast`: cheap conversions still happen in C, while the expensive ones are skipped and their values returned as encoding-tagged Strings of the raw wire bytes.

* Cast, exactly as `:cast => true` does: `NULL` (`nil`), the integer types (TINYINT through BIGINT, YEAR), FLOAT/DOUBLE, BIT, and TINYINT(1)/BIT(1) booleans when `:cast_booleans` is enabled.
* Returned as Strings, exactly as `:cast => false` returns them: DECIMAL, DATE, DATETIME, TIMESTAMP, and TIME -- the types whose casting dominates the cost of materializing a row (BigDecimal, Date, and Time construction).
* Everything else (CHAR/VARCHAR/TEXT, blobs, ENUM, SET, JSON, ...) is already a String and is identical to `:cast => true`.

``` ruby
result = client.query("SELECT * FROM table", :cast => :fast)
```

This is for callers that consume mysql2 results directly -- raw-mysql2 pipelines, ETL jobs, and applications that do their own value parsing -- where DECIMAL and temporal columns are often passed through or parsed lazily, and paying BigDecimal/Time construction for every cell up front is waste. Your code must be prepared to receive Strings for those columns. Note that Active Record does not use this option.

Any `:cast` value other than the exact symbol `:fast` (or `false`/`nil`) keeps meaning full casting.

Prepared statements honor `:cast => false` and `:cast => :fast` too: result columns are bound as strings, so the client library delivers each value's string form from the binary protocol. Those strings are value-equivalent to the text protocol's, and byte-identical for every column type in the spec suite's parity matrix, under both libmysqlclient and libmariadb. Pass `:cast` to `Statement#execute` (or set it client-wide): non-streaming `#execute` materializes rows internally with `#each`, so a `:cast` passed to a later `Result#each` call only applies to rows not already materialized.

### Async

NOTE: Not supported on Windows.

`Mysql2::Client` takes advantage of the MySQL C API's (undocumented) non-blocking function mysql_send_query for *all* queries.
But, in order to take full advantage of it in your Ruby code, you can do:

``` ruby
client.query("SELECT sleep(5)", :async => true)
```

Which will return nil immediately. At this point you'll probably want to use some socket monitoring mechanism
like EventMachine or even IO.select. Once the socket becomes readable, you can do:

``` ruby
# result will be a Mysql2::Result instance
result = client.async_result
```

NOTE: Because of the way MySQL's query API works, this method will block until the result is ready.
So if you really need things to stay async, it's best to just monitor the socket with something like EventMachine.
If you need multiple query concurrency take a look at using a connection pool.

### Query timing

Every `Mysql2::Result` carries the server round trip that produced it, measured in C on a monotonic clock:

``` ruby
result = client.query("SELECT * FROM table")
result.query_time # => 0.000542 (Float seconds)
```

The bracket opens when the command is written to the connection and closes when its first response has been fully read. Server execution and network time to the first response are in; buffering the remaining rows, casting values into Ruby objects, and GVL waits after the first response are out -- so it answers "how slow was the server?" without the noise a Ruby-level stopwatch around `#query` picks up. The reading is the round trip as observed by the calling thread: on a quiet process it matches the wire, while under heavy GVL contention it includes time the thread spent waiting to be rescheduled mid-round-trip, like any thread-observed timing in CRuby.

For a query issued with `:async => true` the bracket closes inside `#async_result`, so time between the response becoming readable and that call is included. `#query_time` is `nil` when no reading applies: the second and later result sets of a multi-statement command, retrieved via `#store_result`.

### Row Caching

By default, Mysql2 will cache rows that have been created in Ruby (since this happens lazily).
This is especially helpful since it saves the cost of creating the row in Ruby if you were to iterate over the collection again.

If you only plan on using each row once, then it's much more efficient to disable this behavior by setting the `:cache_rows` option to false.
This would be helpful if you wanted to iterate over the results in a streaming manner. Meaning the GC would cleanup rows you don't need anymore as you're iterating over the result set.

### Streaming

`Mysql2::Client` can optionally only fetch rows from the server on demand by setting `:stream => true`. This is handy when handling very large result sets which might not fit in memory on the client.

``` ruby
result = client.query("SELECT * FROM really_big_Table", :stream => true)
```

There are a few things that need to be kept in mind while using streaming:

* `:cache_rows` is ignored currently. (if you want to use `:cache_rows` you probably don't want to be using `:stream`)
* You must fetch all rows in the result set of your query before you can make new queries. (i.e. with `Mysql2::Result#each`)

Read more about the consequences of using `mysql_use_result` (what streaming is implemented with) here: [https://dev.mysql.com/doc/c-api/9.7/en/mysql-use-result.html](https://dev.mysql.com/doc/c-api/9.7/en/mysql-use-result.html).

#### Prepared statement streaming and prefetch

Prepared statements stream differently: `Statement#execute(stream: true)` opens a read-only server-side cursor and fetches one row per network round trip. Pass `stream: {size: N}` to fetch N rows per round trip instead:

``` ruby
statement = client.prepare("SELECT * FROM really_big_table")
result = statement.execute(stream: { size: 1000 }, cache_rows: false)
```

`stream: true` is equivalent to `stream: {size: 1}`. `size` bounds how many rows land in client memory per batch, so it trades peak memory for fewer round trips — the win scales with network latency to the server and is barely visible against a local socket.

The two streaming implementations don't share this knob: `Client#query(stream: true)` is `mysql_use_result`, where the server pushes rows and there is no prefetch to size, so `Client#query` raises `ArgumentError` if given `stream: {size: N}`.

### Lazy Everything

Well... almost ;)

Field name strings/symbols are shared across all the rows so only one object is ever created to represent the field name for an entire dataset.

Rows themselves are lazily created in ruby-land when an attempt to yield it is made via #each.
For example, if you were to yield 4 rows from a 100 row dataset, only 4 hashes will be created. The rest will sit and wait in C-land until you want them (or when the GC goes to cleanup your `Mysql2::Result` instance).
Now say you were to iterate over that same collection again, this time yielding 15 rows - the 4 previous rows that had already been turned into ruby hashes would be pulled from an internal cache, then 11 more would be created and stored in that cache.
Once the entire dataset has been converted into ruby objects, Mysql2::Result will free the Mysql C result object as it's no longer needed.

This caching behavior can be disabled by setting the `:cache_rows` option to false.

As for field values themselves, I'm workin on it - but expect that soon.

## Compatibility

This gem is tested with the following Ruby versions on Linux and macOS:

* Ruby MRI 2.7, 3.0, 3.1, 3.2, 3.3, 3.4, 4.0

This gem is tested with the following MySQL and MariaDB versions:

* MySQL 8.0, 8.4, 9.7
* MySQL Connector/C 6.0, 6.1, 8.0 (primarily on Windows)
* MariaDB 10.6, 10.11, 11.4
* MariaDB Connector/C 2.x, 3.x

### Ruby on Rails / Active Record

* mysql2 0.5.x works with Rails / Active Record 4.2.11, 5.0.7, 5.1.6, and higher.
* mysql2 0.4.x works with Rails / Active Record 4.2.5 - 5.0 and higher.
* mysql2 0.3.x works with Rails / Active Record 3.1, 3.2, 4.x, 5.0.
* mysql2 0.2.x works with Rails / Active Record 2.3 - 3.0.

### Asynchronous Active Record

Please see the [em-synchrony](https://github.com/igrigorik/em-synchrony) project for details about using EventMachine with mysql2 and Rails.

### Sequel

Sequel includes a mysql2 adapter in all releases since 3.15 (2010-09-01).
Use the prefix "mysql2://" in your connection specification.

### EventMachine

The mysql2 EventMachine deferrable api allows you to make async queries using EventMachine,
while specifying callbacks for success for failure. Here's a simple example:

``` ruby
require 'mysql2/em'

EM.run do
  client1 = Mysql2::EM::Client.new
  defer1 = client1.query "SELECT sleep(3) as first_query"
  defer1.callback do |result|
    puts "Result: #{result.to_a.inspect}"
  end

  client2 = Mysql2::EM::Client.new
  defer2 = client2.query "SELECT sleep(1) second_query"
  defer2.callback do |result|
    puts "Result: #{result.to_a.inspect}"
  end
end
```

## Benchmarks and Comparison

The mysql2 gem converts MySQL field types to Ruby data types in C code, providing a serious speed benefit.

The do_mysql gem also converts MySQL fields types, but has a considerably more complex API and is still ~2x slower than mysql2.

The mysql gem returns only nil or string data types, leaving you to convert field values to Ruby types in Ruby-land, which is much slower than mysql2's C code.

For a comparative benchmark, the script below performs a basic "SELECT * FROM"
query on a table with 30k rows and fields of nearly every Ruby-representable
data type, then iterating over every row using an #each like method yielding a
block:

``` sh
         user       system     total       real
Mysql2   0.750000   0.180000   0.930000   (1.821655)
do_mysql 1.650000   0.200000   1.850000   (2.811357)
Mysql    7.500000   0.210000   7.710000   (8.065871)
```

These results are from the `query_with_mysql_casting.rb` script in the benchmarks folder.

## Development

Use 'bundle install' to install the necessary development and testing gems:

``` sh
bundle install
rake
```

The tests require the "test" database to exist, and expect to connect
both as root and the running user, both with a blank password:

``` sql
CREATE DATABASE test;
CREATE USER '<user>'@'localhost' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON test.* TO '<user>'@'localhost';
```

You can change these defaults in the spec/configuration.yml which is generated
automatically when you run rake (or explicitly `rake spec/configuration.yml`).

For a normal installation on a Mac, you most likely do not need to do anything,
though.

## I'm running an older version of Rails and need a back-ported feature

Requests to backport features, bug fixes, or newer MySQL/MariaDB
compatibility to old mysql2 release lines can't be honored. Keeping old
branches working would suggest they're properly supported and maintained
when they aren't. An EOL Rails or Ruby version isn't receiving security
patches either, and testing in CI becomes impossible over time as CI
providers prune old runtime images.

Keeping an older application running means taking responsibility for
its older open-source dependencies.
For example, to use
Rails 3.2 with a newer mysql2 gem:

1. Fork Rails and set the needed version branch as the default, e.g.
   [`3-2-stable`](https://github.com/rails/rails/tree/3-2-stable).
2. Edit
   [`mysql2_adapter.rb`](https://github.com/rails/rails/blob/3-2-stable/activerecord/lib/active_record/connection_adapters/mysql2_adapter.rb#L1-L6)
   and change the `gem 'mysql2', '~> 0.3.10'` line to the needed version
   constraint.
3. Point the Gemfile at the fork instead of the `rails` gem, using
   [Bundler's git source](https://bundler.io/guides/git.html).
4. Test the combination in your actual dev, test, and production
   environments.

## Special Thanks

* Eric Wong - for the contribution (and the informative explanations) of some thread-safety, non-blocking I/O and cleanup patches. You rock dude
* [Yury Korolev](https://github.com/yury) - for TONS of help testing the Active Record adapter
* [Aaron Patterson](https://github.com/tenderlove) - tons of contributions, suggestions and general badassness
* [Mike Perham](https://github.com/mperham) - Async Active Record adapter (uses Fibers and EventMachine)
* [Aaron Stone](https://github.com/sodabrew) - additional client settings, local files, microsecond time, maintenance support
* [Kouhei Ueno](https://github.com/nyaxt) - for the original work on Prepared Statements way back in 2012
* [John Cant](https://github.com/johncant) - polishing and updating Prepared Statements support
* [Justin Case](https://github.com/justincase) - polishing and updating Prepared Statements support and getting it merged
* [Tamir Duberstein](https://github.com/tamird) - for help with timeouts and all around updates and cleanups
* [Jun Aruga](https://github.com/junaruga) - for migrating CI tests to GitHub Actions and other improvements
