require "redis"

class MyRedis
  def initialize
    @host = "localhost"
    @port = "6379"
    @db = "1"
    @password = nil
  end

  def connect
    Redis.new(
      host: @host,
      port: @port,
      db: @db,
      password: @password
    )
  end
end
