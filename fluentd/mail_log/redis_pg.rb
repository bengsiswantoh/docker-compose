# require "json"
require "redis"
# require "pg"

# pg = PG::Connection.connect(
#   host: "192.168.1.70",
#   dbname: "email_development",
#   user: "postgres",
#   password: "postgres"
# )

# @schema = "test"
# query = "SELECT id, recipient, process_start, queued_as FROM #{@schema}.mail_logs"
# data = []
# result = pg.exec(query, data)

# result.first

redis = Redis.new({
  db: 1
})

# puts redis.set("log-test-42Nhgj4NWczDrsh", "a")
puts redis.get("log-test-43ZFy65MKlz17d7")
# puts redis.del("log-test-42Nhgj4NWczDrsh")

# keys = redis.keys
# keys = redis.keys("log-test*")

# keys.each do |key|
#   puts redis.get("#{key}")
# end

# puts redis.flushall


