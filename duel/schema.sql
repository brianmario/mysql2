-- The tables the benchmarks read, loaded into each worker's own server
-- as it starts (see .duel.rb). Every value is computed from the row's
-- number, so each server has the same rows.

-- An application's typical table: 1,000 posts.
CREATE TABLE posts (
  id INT NOT NULL PRIMARY KEY,
  author_id INT NOT NULL,
  title VARCHAR(255) NOT NULL,
  body TEXT NOT NULL,
  published TINYINT(1) NOT NULL,
  score DOUBLE NOT NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  KEY index_posts_on_author_id (author_id)
) DEFAULT CHARSET=utf8mb4;

INSERT INTO posts
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
SELECT
  n,
  n MOD 50,
  CONCAT('Post ', n, ': notes on indexes, caching and café menus'),
  REPEAT('Lorem ipsum dolor sit amet, consectetur adipiscing elit. ', 1 + n MOD 8),
  n MOD 3 = 0,
  n * 1.25,
  TIMESTAMP('2026-01-01 08:00:00') + INTERVAL n HOUR,
  TIMESTAMP('2026-01-01 08:00:00') + INTERVAL n * 61 SECOND + INTERVAL n * 1001 MICROSECOND
FROM seq;

-- 100 rows with a column of each type mysql2 casts, which the
-- benchmarks select a few at a time.
CREATE TABLE typed (
  id INT NOT NULL PRIMARY KEY,
  tiny_int TINYINT NOT NULL,
  small_int SMALLINT NOT NULL,
  medium_int MEDIUMINT NOT NULL,
  int_value INT NOT NULL,
  big_int BIGINT NOT NULL,
  float_value FLOAT NOT NULL,
  double_value DOUBLE NOT NULL,
  price DECIMAL(10, 2) NOT NULL,
  ratio DECIMAL(12, 6) NOT NULL,
  balance DECIMAL(30, 10) NOT NULL,
  quantity DECIMAL(10, 0) NOT NULL,
  birthday DATE NOT NULL,
  starts_on DATE NOT NULL,
  ends_on DATE NOT NULL,
  happened_at DATETIME NOT NULL,
  recorded_at DATETIME(6) NOT NULL,
  stamped_at TIMESTAMP NOT NULL,
  opens_at TIME NOT NULL,
  lasted TIME(3) NOT NULL,
  document JSON NOT NULL,
  name VARCHAR(100) NOT NULL,
  note TEXT NOT NULL,
  payload BLOB NOT NULL
) DEFAULT CHARSET=utf8mb4;

INSERT INTO typed
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100)
SELECT
  n,
  n - 50,
  n * 300 - 15000,
  n * 80000,
  n * 20000000,
  n * 90000000000000,
  n / 7,
  n * 3.141592653589793,
  n * 19.99,
  n / 3,
  n * 123456789.0123456789,
  n * 10,
  DATE('1970-01-01') + INTERVAL n * 97 DAY,
  DATE('2026-01-01') + INTERVAL n DAY,
  DATE('2026-01-01') + INTERVAL n + 30 DAY,
  TIMESTAMP('2026-01-01 08:00:00') + INTERVAL n * 3607 SECOND,
  TIMESTAMP('2026-01-01 08:00:00') + INTERVAL n * 3607 SECOND + INTERVAL n * 123457 MICROSECOND,
  TIMESTAMP('2026-01-01 08:00:00') + INTERVAL n * 61 MINUTE,
  SEC_TO_TIME(n * 863),
  SEC_TO_TIME(n * 5000 + 0.125),
  JSON_OBJECT('id', n, 'name', CONCAT('user', n), 'tags', JSON_ARRAY('a', 'b', 'c'), 'active', n MOD 2 = 0,
    'address', JSON_OBJECT('city', 'Zürich', 'zip', 8000 + n)),
  CONCAT('Name ', n, ' Müller'),
  REPEAT('Some notes about this row. ', 1 + n MOD 5),
  UNHEX(REPEAT(LPAD(HEX(n), 2, '0'), 32))
FROM seq;
