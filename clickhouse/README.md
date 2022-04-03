# ClickHouse table design and considerations

## Projections vs Materialized View
Projections provide a more consistent and optimized way to create correlation on top of `DNS_LOG`. Since Projections are inside the `DNS_LOG` table rather than a completely new one, it makes it easier to work on TTL in one table rather than many tables, it can also have an impact on compression rate. 

- set optimization options in session
```sql
set allow_experimental_projection_optimization=1;
```

Note that the above setting is *enabled* by default, set in `users.xml`'s default profile section.

## Advance optimization queries

- See Size on disk and raw size for each column ([reference](https://kb.altinity.com/altinity-kb-schema-design/codecs/altinity-kb-how-to-test-different-compression-codecs/#useful-queries))
```sql
SELECT
    database,
    table,
    count() AS parts,
    uniqExact(partition_id) AS partition_cnt,
    sum(rows),
    formatReadableSize(sum(data_compressed_bytes) AS comp_bytes) AS comp,
    formatReadableSize(sum(data_uncompressed_bytes) AS uncomp_bytes) AS uncomp,
    uncomp_bytes / comp_bytes AS ratio
FROM system.parts
WHERE active
GROUP BY
    database,
    table
ORDER BY comp_bytes DESC
```

- Use `ttl_only_drop_parts` to manage TTL

by default, `DNS_LOG` table uses a daily partition scheme. Meaning each day's worth of data is stored in a separate partition. Because of that, it's possible to change the way ClickHouse's TTL works to a much faster option:

```sql
ALTER TABLE DNS_LOG MODIFY SETTING ttl_only_drop_parts=1
```

- get the oldest record's date
```sql
SELECT * FROM DNS_LOG WHERE DnsDate > Now() - toIntervalDay(31) LIMIT 10 
```

- show table settings
```sql
SELECT * FROM system.tables WHERE name = 'DNS_LOG' FORMAT Vertical;  
```

## Migration from the old table design
Unfortunately, ClickHouse doesn't support updates to `PRIMARY KEY` in the table. Because of that, It's easier to:
- stop `dnsmonster` process
- rename the old `DNS_LOG` table [using a simple query](https://clickhouse.com/docs/en/sql-reference/statements/rename/)
- create the new `DNS_LOG` table using `tables-v2.sql` using the `clickhouse-client`
  - `docker-compose exec ch /bin/sh -c 'cat /tmp/tables.sql | clickhouse-client -h 127.0.0.1 --multiquery'`
- update `dnsmonster` package to the latest version using v2 schema
- start the `dnsmonster` process


## Troubleshoot ClickHouse

ClickHouse is set to store data for 30 days through the `TTL` parameter while creating the table. However, I've experienced issues with the consistency of that. Sometimes cleaning up the old data doesn't work properly so you'll end up with residual old data. To troubleshoot and interact with ClickHouse, we need to send SQL queries. There are a few ways to do so in a containerized environment:

- Run a shell inside the container and run the `clickhouse-client` tool and get an interactive SQL shell
- Install `clickhouse-client` on the HOST system and connect to 127.0.0.1:9000 and get an interactive SQL shell
- Run queries with `curl` or `wget` using Clickhouse's builtin HTTP API. 


```sh
curl -G localhost:8005 --data-urlencode "query=SELECT COUNT(*) FROM DNS_LOG WHERE DnsDate < '2021-12-31'"
```

Above `curl` command is very simple, the parameter `query` equals to the SQL query you wish to send to the ClickHouse server and returns the result. I used `data-urlencode` and `-G` so the text inside "" is readable and I don't have to url-encode them myself. Now let's focus on the query itself:

```sql
SELECT COUNT(*) FROM DNS_LOG WHERE DnsDate < '2021-12-31'
```

`DNS_LOG` is the main table for `dnsmonster`. everything is stored in that table. Count(*) returns the number of rows rather than the actual values, and the `WHERE` clause is pretty self explanatory. It adds an `if` clause so we only get the number of rows where DnsDate parameter is before the date mentioned. Here's a slightly better query to get us number of rows present that are dated more than 30 days ago:

```sql
SELECT COUNT(*) FROM DNS_LOG WHERE DnsDate < Now() - toIntervalDay(30)
```

above query is very similar to the previous one, with the notable difference that it calculates the "30 days ago" using the expression `Now() - toIntervalDay(30)`.

## Disk is full

First let's see how can we get the current TTL value of a table in `clickhouse`:

```sql
SELECT engine_full FROM system.tables WHERE database = 'default' AND name = 'DNS_LOG'
```

above should give you something like this:
```sql
MergeTree PARTITION BY toYYYYMMDD(DnsDate) PRIMARY KEY (timestamp, Server, cityHash64(ID)) ORDER BY (timestamp, Server, cityHash64(ID)) SAMPLE BY cityHash64(ID) TTL DnsDate + toIntervalDay(30) SETTINGS index_granularity = 8192, merge_with_ttl_timeout = 3600
```

as you can see above, the TTL command is `DnsDate + toIntervalDay(30)`, which points to a 30 days TTL. So if you run a query that shows you the count of logs before 30 days ago, in theory you should get a zero. But that's rarely the case. Because Clickhouse runs the cleanup and TTL asynchronously, and sometimes it's running it while writing a huge amount of log files, it gets timed out and data remains in the database. There are two workarounds to this problem:

1) increase the TTL timeout. Running the below query increases the TTL timeout to 3600 seconds (1 hour):

```sql
ALTER TABLE default.DNS_LOG MODIFY SETTING merge_with_ttl_timeout = 3600
```

2) force TTL synchronously. Below query is used to force cleanup the db:

```sql
OPTIMIZE TABLE default.DNS_LOG FINAL
```

IMPORTANT NOTE: `ALTER` and `OPTIMIZE` might not run over the HTTP API. Also, HTTP doesn't have 1 hour timeout so you have a chance of breaking the HTTP connection before the cleanup finishes, so `curl` is not recommended for this. When you SSH into a host, you can run this command instead:

```sh
docker exec clickhouse-production clickhouse-client -q "OPTIMIZE TABLE default.DNS_LOG FINAL"
```
As mentioned, the timeout for the above command is 1 hour. So it's recommended you run it in a `tmux` or a [`screen`](https://linuxize.com/post/how-to-use-linux-screen/) session. That way you won't lose the command's execution if your SSH session terminates by any chance. 

### Last resort
If none of the above methods work, we need to locate the old data's partition and delete them altogether ([reference](https://clickhouse.com/docs/en/sql-reference/statements/alter/partition/#alter_drop-partition)). It's the fastest option available. As seen above, `PARTITION BY toYYYYMMDD(DnsDate)` indicates that `DNS_LOG` data is partitioned on a daily basis. To confirm, let's issue a query to fetch all the partitions of a table:

```sql
SELECT * FROM system.parts WHERE table = 'DNS_LOG' LIMIT 10 FORMAT TSKV; --format is optional. I put that in there to illustrate it easier
```

so removing old data's partitions should be reasonably straightforward. Use the following:

```sql
ALTER TABLE default.DNS_LOG DROP PARTITION '20220107';
```

The above drops the partition for the day '20220107'. Unfortunately, there's no safe way to drop all partitions older than a certain day at the same time. You can run a bash script that does this automatically though:

```bash
#!/bin/bash

# Simple script to delete partitions older than 30 days. Useful if TTL functionality is misbehaving or you've altered TTL manually after creating partitions. 

DAYS_TO_KEEP=31
CONTAINER_NAME=clickhouse-production
CLICKHOUSE_ADDRESS=localhost:8123

# get the earliest date of partitions from system tables
EARLIEST_DATE=`docker exec ${CONTAINER_NAME} clickhouse-client -q "SELECT partition FROM system.parts WHERE table = 'DNS_LOG' ORDER BY partition LIMIT 1"`

# latest acceptable date to delete partitions
LATEST_DATE=`date +%Y%m%d -d "-${DAYS_TO_KEEP} days"`

# calculate the number of days between the two
let DIFF=($(date +%s -d ${LATEST_DATE})-$(date +%s -d ${EARLIEST_DATE}))/86400
DIFF=$(($DIFF+$DAYS_TO_KEEP))

for i in `seq $DIFF -1 $DAYS_TO_KEEP`
do
  DATE=`date +%Y%m%d -d "-$i days"`
  echo "Deleting partition ${DATE}"
  docker exec ${CONTAINER_NAME} clickhouse-client -q "ALTER TABLE DNS_LOG DROP PARTITION ${DATE}"
done
```