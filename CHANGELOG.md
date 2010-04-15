# Changelog

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