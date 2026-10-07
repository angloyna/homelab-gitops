# Kafka to ClickHouse

A walk through how the two talk to each other, on the cluster's own Kafka
(`apps/kafka`) and ClickHouse (`apps/clickhouse`). Everything here is run
from a laptop on the tailnet; nothing is committed to the cluster, so it is
safe to redo from the top.

The shape, in one line: **ClickHouse pulls.** There is no connector in
between. ClickHouse has a table engine that *is* a Kafka consumer, and a
materialized view copies each batch it reads into a normal table. The
Kafka engine table is a pipe, not storage.

```
producer ──> Kafka topic `events` ──(consumer group)──> Kafka engine table ──(MV)──> MergeTree table
```

## 0. Addresses

| From | Bootstrap address |
|---|---|
| inside the cluster (ClickHouse) | `main-kafka-bootstrap.kafka.svc.cluster.local:9092` |
| laptop on the tailnet | `kafka.tail60f7ac.ts.net:9094` |

The tailnet one is a Kafka *bootstrap*: the client connects there once,
learns the broker's advertised address (`kafka-0.tail60f7ac.ts.net:9094`,
another tailnet device), and talks to that. Both have to resolve, which is
why there are two devices for one broker.

## 1. See the topic

The `events` topic is created by git (`apps/kafka/manifests/kafka.yaml`,
a `KafkaTopic`), three partitions, one replica. From the cluster:

```sh
kubectl -n kafka get kafkatopics
kubectl -n kafka run -it --rm topics --image=quay.io/strimzi/kafka:1.2.0-kafka-4.3.1 --restart=Never -- \
  bin/kafka-topics.sh --bootstrap-server main-kafka-bootstrap:9092 --describe --topic events
```

## 2. The ClickHouse side, before any data

In `/play` or DataGrip, as `admin`:

```sql
-- The destination: a real table, ordered the way you'll query it.
CREATE TABLE events
(
    ts        DateTime,
    user_id   UInt32,
    kind      LowCardinality(String),
    value     Float64,
    -- kept from Kafka so you can see where each row came from
    _topic     String,
    _partition UInt16,
    _offset    UInt64
)
ENGINE = MergeTree
ORDER BY (kind, ts);

-- The pipe: a consumer in group `clickhouse`, reading JSON lines.
CREATE TABLE events_queue
(
    ts       DateTime,
    user_id  UInt32,
    kind     String,
    value    Float64
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'main-kafka-bootstrap.kafka.svc.cluster.local:9092',
    kafka_topic_list  = 'events',
    kafka_group_name  = 'clickhouse',
    kafka_format      = 'JSONEachRow',
    kafka_num_consumers = 1;

-- The pump: every batch the pipe reads lands in the table.
CREATE MATERIALIZED VIEW events_mv TO events AS
SELECT ts, user_id, kind, value, _topic, _partition, _offset
FROM events_queue;
```

Two things worth knowing about that:

- `events_queue` is not for `SELECT`. Reading from it consumes the
  messages, once, and they are gone from the view's point of view. The
  materialized view is what reads it; you read `events`.
- The consumer group name is how Kafka remembers where ClickHouse is up to.
  Drop and recreate `events_queue` with the same group and it resumes;
  change the group and it starts from wherever `auto.offset.reset` says,
  which for the Kafka engine defaults to the earliest offset.

Check the consumer registered:

```sql
SELECT table, consumer_id, assignments.topic, assignments.partition_id, last_poll_time
FROM system.kafka_consumers;
```

## 3. Produce something

From the cluster, the Kafka console producer, one JSON object per line:

```sh
kubectl -n kafka run -it --rm producer --image=quay.io/strimzi/kafka:1.2.0-kafka-4.3.1 --restart=Never -- \
  bin/kafka-console-producer.sh --bootstrap-server main-kafka-bootstrap:9092 --topic events
```

Paste a few:

```
{"ts":"2026-10-07 20:00:00","user_id":1,"kind":"click","value":1}
{"ts":"2026-10-07 20:00:05","user_id":2,"kind":"view","value":0.5}
{"ts":"2026-10-07 20:00:09","user_id":1,"kind":"purchase","value":42.0}
```

Ctrl-D to finish. Or, from the laptop with `kcat` (`brew install kcat`):

```sh
kcat -b kafka.tail60f7ac.ts.net:9094 -t events -P <<'EOF'
{"ts":"2026-10-07 20:01:00","user_id":3,"kind":"click","value":1}
EOF
```

## 4. Watch it arrive

The Kafka engine polls and flushes on a timer (`kafka_flush_interval_ms`,
default 7.5s) or a batch size (`kafka_max_block_size`), whichever first, so
give it a few seconds:

```sql
SELECT * FROM events ORDER BY ts;

SELECT kind, count(), sum(value) FROM events GROUP BY kind;

-- Where ClickHouse is up to, per partition
SELECT assignments.partition_id, assignments.current_offset FROM system.kafka_consumers ARRAY JOIN assignments;
```

And the same offsets from Kafka's side, which should match:

```sh
kubectl -n kafka run -it --rm groups --image=quay.io/strimzi/kafka:1.2.0-kafka-4.3.1 --restart=Never -- \
  bin/kafka-consumer-groups.sh --bootstrap-server main-kafka-bootstrap:9092 --describe --group clickhouse
```

`LAG` in that output is the number of messages Kafka has that ClickHouse
hasn't read yet. Zero means caught up.

## 5. Load it for real

A few hand-typed rows show the plumbing; a few hundred thousand show the
point. ClickHouse can be its own producer, which is the quickest way to
get volume: a `Kafka` engine table accepts `INSERT`, and the materialized
view on the other side consumes it back.

```sql
INSERT INTO events_queue
SELECT
    now() - number AS ts,
    rand() % 1000 AS user_id,
    ['click', 'view', 'purchase'][1 + rand() % 3] AS kind,
    round(rand() % 10000 / 100, 2) AS value
FROM numbers(500000);
```

Then `SELECT count() FROM events` climbs over the next seconds, and the
group-by from step 4 runs over half a million rows in milliseconds, which
is the thing Kafka plus ClickHouse is for: Kafka absorbs the write stream,
ClickHouse answers the questions.

## 6. Things to try next

- **Schema change.** Add a column to the producer's JSON. The Kafka engine
  table ignores unknown fields by default (`input_format_skip_unknown_fields`),
  so nothing breaks; the new field is dropped until you add it to
  `events_queue`, `events` and the view, in that order, with
  `DETACH TABLE events_queue` first so the consumer pauses.
- **Bad messages.** Produce a line that isn't JSON. With
  `kafka_handle_error_mode = 'stream'` on the engine table, the broken rows
  come through with `_error` and `_raw_message` set instead of stalling the
  consumer; a second materialized view can route them to a dead-letter
  table.
- **Parallelism.** The topic has three partitions. Set
  `kafka_num_consumers = 3` and `kafka_thread_per_consumer = 1` on the
  engine table and watch `system.kafka_consumers` grow to three, one per
  partition.
- **Scale.** When the third node exists, the node pool goes to three
  replicas and the topic to three replicas; nothing on the ClickHouse side
  changes except the broker list can stay as the bootstrap Service.

## Tearing it down

```sql
DROP VIEW events_mv;
DROP TABLE events_queue;
DROP TABLE events;
```

The topic keeps its messages for seven days (`retention.ms` on the
`KafkaTopic`); the consumer group's committed offsets stay with Kafka until
they expire, so recreating the engine table with the same group name picks
up where it left off.
