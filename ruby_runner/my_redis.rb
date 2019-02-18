require "redis"
require "connection_pool"

class MyRedis
  def initialize(host = "redis", db = "1", password = nil, port ="6379")
    @host = host
    @port = port
    @db = db
    @password = password
  end

  def connect
    Redis.new(
      host: @host,
      port: @port,
      db: @db,
      password: @password
    )
  end

  def connect_with_pool(size, timeout)
    ConnectionPool.new(size: size, timeout: timeout) {
      connect()
    }
  end
end
