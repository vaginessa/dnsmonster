CREATE TABLE IF NOT EXISTS DNS_LOG (
  timestamp DateTime64, -- packet timestamp
  IndexTime DateTime64, -- index timestamp
  Server LowCardinality(String),
  IPVersion UInt8,
  SrcIP UInt64,
  DstIP UInt64,
  Protocol FixedString(3),
  QR UInt8,
  OpCode UInt8,
  Class UInt16,
  Type UInt16,
  Edns0Present UInt8,
  DoBit UInt8,
  FullQuery String,
  ResponseCode UInt8,
  Question String CODEC(ZSTD(1)),
  Size UInt16
) 
  ENGINE = MergeTree()
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY (toStartOfHour(timestamp), Server, reverse(Question), toUnixTimestamp(timestamp))
  ORDER BY (toStartOfHour(timestamp), Server,  reverse(Question), toUnixTimestamp(timestamp))
  SAMPLE BY toUnixTimestamp(timestamp)
  TTL toDate(timestamp) + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192;


-- View for top queried domains
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_DOMAIN_COUNT
ENGINE=SummingMergeTree
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY (toDate(timestamp), Server, QH)
  ORDER BY (toDate(timestamp), Server, QH)
  SAMPLE BY QH
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS SELECT toDate(timestamp) as date, toStartOfMinute(timestamp) as timestamp, Server, Question, cityHash64(Question) as QH, count(*) as c FROM DNS_LOG WHERE QR=0 GROUP BY date, timestamp, Server, Question;

-- View for unique domain count
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_DOMAIN_UNIQUE
ENGINE=AggregatingMergeTree(date,(timestamp, Server), 8192) AS
  SELECT toDate(timestamp) as date, timestamp, Server, uniqState(Question) AS UniqueDnsCount FROM DNS_LOG WHERE QR=0 GROUP BY date,Server, timestamp;

-- View for count by protocol
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_PROTOCOL
ENGINE=SummingMergeTree
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY (Server, PH)
  ORDER BY (Server, PH)
  SAMPLE BY PH
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS SELECT toStartOfMinute(timestamp) as timestamp, Server, Protocol, cityHash64(Protocol) as PH, count(*) as c FROM DNS_LOG GROUP BY Server, timestamp, Protocol;


-- View with packet sizes
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_GENERAL_AGGREGATIONS
ENGINE=AggregatingMergeTree(date,(timestamp, Server), 8192) AS
SELECT toDate(timestamp) as date, timestamp, Server, sumState(Size) AS TotalSize, avgState(Size) AS AverageSize FROM DNS_LOG GROUP BY date, Server, timestamp;

-- View with edns information
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_EDNS
ENGINE=AggregatingMergeTree(date,(timestamp, Server), 8192) AS
  SELECT toDate(timestamp) as date,timestamp, Server, sumState(Edns0Present) as EdnsCount, sumState(DoBit) as DoBitCount FROM DNS_LOG WHERE QR=0 GROUP BY date,Server, timestamp;

-- View wih query OpCode
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_OPCODE
ENGINE=SummingMergeTree
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY  (timestamp, Server, OpCode)
  ORDER BY  (timestamp, Server, OpCode)
  SAMPLE BY OpCode
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS SELECT timestamp, Server, OpCode, count(*) as c FROM DNS_LOG WHERE QR=0 GROUP BY Server, timestamp, OpCode;

-- View with Query Types
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_TYPE
ENGINE=SummingMergeTree 
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY  (timestamp, Server, Type)
  ORDER BY  (timestamp, Server, Type)
  SAMPLE BY Type
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS   SELECT timestamp, Server, Type, count(*) as c FROM DNS_LOG WHERE QR=0 GROUP BY Server, timestamp, Type;

-- View with Query Class
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_CLASS
ENGINE=SummingMergeTree
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY  (timestamp, Server, Class)
  ORDER BY  (timestamp, Server, Class)
  SAMPLE BY Class
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS SELECT timestamp, Server, Class, count(*) as c FROM DNS_LOG WHERE QR=0 GROUP BY Server, timestamp, Class;  

-- View with query responses
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_RESPONSECODE
ENGINE=SummingMergeTree
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY  (timestamp, Server, ResponseCode)
  ORDER BY  (timestamp, Server, ResponseCode)
  SAMPLE BY ResponseCode
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS SELECT timestamp, Server, ResponseCode, count(*) as c FROM DNS_LOG WHERE QR=1 GROUP BY Server, timestamp, ResponseCode;    

-- View with Source IP Prefix
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_SRCIP_MASK
ENGINE=SummingMergeTree
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY  (timestamp, Server, IPVersion, SrcIP)
  ORDER BY  (timestamp, Server, IPVersion, SrcIP)
  SAMPLE BY SrcIP
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS SELECT timestamp, Server, IPVersion, SrcIP, count(*) as c FROM DNS_LOG GROUP BY Server, timestamp, IPVersion, SrcIP ;  

-- View with Destination IP Prefix
CREATE MATERIALIZED VIEW IF NOT EXISTS DNS_DSTIP_MASK
ENGINE=SummingMergeTree
  PARTITION BY toYYYYMMDD(timestamp)
  PRIMARY KEY  (timestamp, Server, IPVersion, DstIP)
  ORDER BY  (timestamp, Server, IPVersion, DstIP)
  SAMPLE BY DstIP
  TTL toDate(timestamp)  + INTERVAL 30 DAY -- DNS_TTL_VARIABLE
  SETTINGS index_granularity = 8192
  AS SELECT timestamp, Server, IPVersion, DstIP, count(*) as c FROM DNS_LOG GROUP BY Server, timestamp, IPVersion, DstIP ;  

-- -- projection for top queried domains
-- alter table DNS_LOG add projection DOMAIN_COUNT 
--    (SELECT toStartOfMinute(timestamp) as t, Server, Question, cityHash64(Question) as QH, count(*) as c GROUP BY QR, t, Server, Question);
-- alter table DNS_LOG materialize projection DOMAIN_COUNT;

-- -- projection for uniuque domain count
-- alter table DNS_LOG add projection DNS_DOMAIN_UNIQUE
--   (SELECT timestamp, Server, uniqState(Question) AS UniqueDnsCount GROUP BY QR, Server, timestamp);
-- alter table DNS_LOG materialize projection DNS_DOMAIN_UNIQUE;

-- -- projection for DNS protocol
-- alter table DNS_LOG add projection DNS_PROTOCOL
--   (SELECT timestamp, Server, Protocol, cityHash64(Protocol) as PH, count(*) as c  GROUP BY Server, timestamp, Protocol);
-- alter table DNS_LOG materialize projection DNS_PROTOCOL;

-- -- projection for packet size
-- alter table DNS_LOG add projection DNS_GENERAL_AGGREGATIONS
--   (SELECT timestamp, Server, sumState(Size) AS TotalSize, avgState(Size) AS AverageSize  GROUP BY Server, timestamp);
-- alter table DNS_LOG materialize projection DNS_GENERAL_AGGREGATIONS;

-- -- projection for eDNS
-- alter table DNS_LOG add projection DNS_EDNS
--   (SELECT timestamp, Server, sumState(Edns0Present) as EdnsCount, sumState(DoBit) as DoBitCount GROUP BY QR, Server, timestamp);
-- alter table DNS_LOG materialize projection DNS_EDNS;

-- -- projection for opCode
-- alter table DNS_LOG add projection DNS_OPCODE
--  (SELECT timestamp, Server, OpCode, count(*) as c  GROUP BY QR, Server, timestamp, OpCode);
-- alter table DNS_LOG materialize projection DNS_OPCODE;

-- -- projection for Query Type
-- alter table DNS_LOG add projection DNS_QUERY_TYPE
--   (SELECT timestamp, Server, Type, count(*) as c  GROUP BY QR, Server, timestamp, Type);
-- alter table DNS_LOG materialize projection DNS_QUERY_TYPE;

-- -- projection for query class
-- alter table DNS_LOG add projection DNS_QUERY_CLASS
--   (SELECT timestamp, Server, Class, count(*) as c  GROUP BY QR, Server, timestamp, Class);  
-- alter table DNS_LOG materialize projection DNS_QUERY_CLASS;

-- -- projection for DNS response code
-- alter table DNS_LOG add projection DNS_RESPONSE_CODE
--   (SELECT timestamp, Server, ResponseCode, count(*) as c  GROUP BY Server, timestamp, ResponseCode);
-- alter table DNS_LOG materialize projection DNS_RESPONSE_CODE; 

-- -- projection for src IP
-- alter table DNS_LOG add projection DNS_SRC_IP
--   (SELECT timestamp, Server, IPVersion, SrcIP, count(*) as c  GROUP BY Server, timestamp, IPVersion, SrcIP );  
-- alter table DNS_LOG materialize projection DNS_SRC_IP;

-- -- projection for dst IP
-- alter table DNS_LOG add projection DNS_DST_IP
--   (SELECT timestamp, Server, IPVersion, DstIP, count(*) as c  GROUP BY Server, timestamp, IPVersion, DstIP );
-- alter table DNS_LOG materialize projection DNS_DST_IP;

-- -- NOTE: this parameter needs to be set either in session settings or the user's profile (https://clickhouse.com/docs/en/operations/settings/#session-settings-intro)
-- set allow_experimental_projection_optimization=1;

-- sample queries

-- new domains over the past 24 hours
-- SELECT DISTINCT Question FROM (SELECT Question  WHERE toStartOfDay(timestamp) > Now() - INTERVAL 1 DAY) AS dns1 LEFT ANTI JOIN (SELECT Question  WHERE toStartOfDay(timestamp) < Now() - INTERVAL 1 DAY  AND toStartOfDay(timestamp) > (Now() - toIntervalDay(10))  ) as dns2 ON dns1.Question = dns2.Question

-- timeline of request count every 5 minutes
-- SELECT toStartOfFiveMinute(timestamp) as t, count()  GROUP BY t ORDER BY t

-- 