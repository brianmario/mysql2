# Changelog

## 0.2.13 (August 16th, 2011)
* fix stupid bug around symbol encoding support (thanks coderrr!)

## 0.2.12 (August 16th, 2011)
* ensure symbolized column names support encodings in 1.9
* plugging sql vulnerability in mysql2 adapter

## 0.2.11 (June 17th, 2011)
* fix bug in Time/DateTime range detection
* (win32) fix bug where the Mysql2::Client object wasn't cleaned up properly if interrupted during a query
* add Mysql2::Result#count (aliased as size) to get the row count for the dataset
  this can be especially helpful if you want to get the number of rows without having to inflate
  the entire dataset into ruby (since this happens lazily)

## 0.2.10 (June 15th, 2011)
* bug fix for Time/DateTime usage depending on 32/64bit Ruby

## 0.2.9 (June 15th, 2011)
* fix a long standing bug where a signal would interrupt rb_thread_select and put the connection in a permanently broken state
* turn on casting in the ActiveRecord again, users can disable it if they need to for performance reasons

## 0.2.8 (June 14th, 2011)
* disable async support, and access to the underlying file descriptor under Windows. It's never worked reliably and ruby-core has a lot of work to do in order to make it possible.
* added support for turning eager-casting off. This is especially useful in ORMs that will lazily cast values upon access.
* added a warning if a 0.2.x release is being used with ActiveRecord 3.1 since both the 0.2.x releases and AR 3.1 have mysql2 adapters, we want you to use the one in AR 3.1
* added Mysql2::Client.escape (class-level method)
* disabled eager-casting in the bundled ActiveRecord adapter (for Rails 3.0 or less)

## 0.2.7 (March 28th, 2011)
* various fixes for em_mysql2 and fiber usage
* use our own Mysql2IndexDefinition class for better compatibility across ActiveRecord versions
* ensure the query is a string earlier in the Mysql2::Client#query codepath for 1.9
* only set binary ruby encoding on fields that have a binary flag *and* encoding set
* a few various optimizations
* add support for :read_timeout to be set on a connection
* Fix to install with MariDB on Windows
* add fibered em connection without activerecord
* fix some 1.9.3 compilation warnings
* add LD_RUN_PATH when using hard coded mysql paths - this should help users with MySQL installed in non-standard locations
* for windows support, duplicate the socket from libmysql and create a temporary CRT fd
* fix for handling years before 1970 on Windows
* fixes to the Fiber adapter
* set wait_timeout maximum on Windows to 2147483
* update supported range for Time objects
* upon being required, make sure the libmysql we're using is the one we were built against
* add Mysql2::Client#thread_id
* add Mysql2::Client#ping
* switch connection check in AR adapter to use Mysql2::Client#ping for efficiency
* prefer linking against thread-safe version of libmysqlclient
* define RSTRING_NOT_MODIFIED for an awesome rbx speed boost
* expose Mysql2::Client#encoding in 1.9, make sure we set the error message and sqlstate encodings accordingly
* do not segfault when raising for invalid charset (found in 1.9.3dev)

## 0.2.6 (October 19th, 2010)
* version bump since the 0.2.5 win32 binary gems were broken

## 0.2.5 (October 19th, 2010)
* fixes for easier Win32 binary gem deployment for targeting 1.8 and 1.9 in the same gem
* refactor of connection checks and management to avoid race conditions with the GC/threading to prevent the unexpected loss of connections
* update the default flags during connection
* add support for setting wait_timeout on AR adapter
* upgrade to rspec2
* bugfix for an edge case where the GC would clean up a Mysql2::Client object before the underlying MYSQL pointer had been initialized
* fix to CFLAGS to allow compilation on SPARC with sunstudio compiler - Anko painting <anko.com+github@gmail.com>

## 0.2.4 (September 17th, 2010)
* a few patches for win32 support from Luis Lavena - thanks man!
* bugfix from Eric Wong to avoid a potential stack overflow during Mysql2::Client#escape
* added the ability to turn internal row caching on/off via the :cache_rows => true/false option
* a couple of small patches for rbx compatibility
* set IndexDefinition#length in AR adapter - Kouhei Yanagita <yanagi@shakenbu.org>
* fix a long-standing data corruption bug - thank you thank you thank you to @joedamato (http://github.com/ice799)
* bugfix from calling mysql_close on a closed/freed connection surfaced by the above fix

## 0.2.3 (August 20th, 2010)
* connection flags can now be passed to the constructor via the :flags key
* switch AR adapter connection over to use FOUND_ROWS option
* patch to ensure we use DateTime objects in place of Time for timestamps that are out of the supported range on 32bit platforms < 1.9.2

## 0.2.2 (August 19th, 2010)
* Change how AR adapter would send initial commands upon connecting
** we can make multiple session variable assignments in a single query
* fix signal handling when waiting on queries
* retry connect if interrupted by signals

## 0.2.1 (August 16th, 2010)
* bring mysql2 ActiveRecord adapter back into gem

## 0.2.0 (August 16th, 2010)
* switch back to letting libmysql manage all allocation/thread-state/freeing for the connection
* cache various numeric type conversions in hot-spots of the code for a little speed boost
* ActiveRecord adapter moved into Rails 3 core
** Don't worry 2.3.x users! We'll either release the adapter as a separate gem, or try to get it into 2.3.9
* Fix for the "closed MySQL connection" error (GH #31)
* Fix for the "can't modify frozen object" error in 1.9.2 (GH #37)
* Introduce cascading query and result options (more info in README)
* Sequel adapter pulled into core (will be in the next release - 3.15.0 at the time of writing)
* add a safety check when attempting to send a query before a result has been fetched

## 0.1.9 (July 17th, 2010)
* Support async ActiveRecord access with fibers and EventMachine (mperham)
* string encoding support for 1.9, respecting Encoding.default_internal
* added support for rake-compiler (tenderlove)
* bugfixes for ActiveRecord driver
** one minor bugfix for TimeZone support
** fix the select_rows method to return what it should according to the docs (r-stu31)
* Mysql2::Client#fields method added - returns the array of field names from a resultset, as strings
* Sequel adapter
** bugfix regarding sybolized field names (Eric Wong)
** fix query logging in Sequel adapter
* Lots of nice code cleanup (tenderlove)
** Mysql2::Error definition moved to pure-Ruby
** Mysql2::client#initialize definition moved to pure-Ruby
** Mysql2::Result partially moved to pure-Ruby

## 0.1.8 (June 2nd, 2010)
* fixes for AR adapter for timezone juggling
* fixes to be able to run benchmarks and specs under 1.9.2

## 0.1.7 (May 22nd, 2010)
* fix a bug when using the disconnect! method on a closed connection in the AR driver

## 0.1.6 (May 14th, 2010)
* more fixes to the AR adapter related to casting
* add missing index creation override method to AR adapter
* added sql_state and error_number methods to the Mysql2::Error exception class

## 0.1.5 (May 12th, 2010)
* quite a few patches from Eric Wong related to thread-safety, non-blocking I/O and general cleanup
** wrap mysql_real_connect with rb_thread_blocking_region
** release GVL for possibly blocking mysql_* library calls
** [cleanup] quiet down warnings
** [cleanup] make all C symbols static
** add Mysql2::Client#close method
** correctly free the wrapped result in case of EOF
** Fix memory leak from the result wrapper struct itself
** make Mysql2::Client destructor safely non-blocking
* bug fixes for ActiveRecord adapter
** added casting for default values since they all come back from Mysql as strings (!?!)
** missing constant was added
** fixed a typo in the show_variable method
* switched over sscanf for date/time parsing in C
* made some specs a little finer-grained
* initial Sequel adapter added
* updated query benchmarks to reflect the difference between casting in C and in Ruby

## 0.1.4 (April 23rd, 2010)
* optimization: implemented a local cache for rows that are lazily created in ruby during iteration. The MySQL C result is freed as soon as all the results have been cached
* optimization: implemented a local cache for field names so every row reuses the same objects as field names/keys
* refactor the Mysql2 connection adapter for ActiveRecord to not extend the Mysql adapter - now being a free-standing connection adapter

## 0.1.3 (April 15th, 2010)
* added an EventMachine Deferrable API
* added an ActiveRecord connection adapter
** should be compatible with 2.3.5 and 3.0 (including Arel)

## 0.1.2 (April 9th, 2010)
* fix a bug (copy/paste fail) around checking for empty TIME values and returning nil (thanks @marius)

## 0.1.1 (April 6th, 2010)
* added affected_rows method (mysql_affected_rows)
* added last_id method (last_insert_id)
* enable reconnect option by default
* added initial async query support
* updated extconf (thanks to the mysqlplus project) for easier gem building

## 0.1.0 (April 6th, 2010)
* initial release