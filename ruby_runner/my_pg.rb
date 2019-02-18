require "pg"
require "connection_pool"

class MyPG
  def initialize(host = "postgres", dbname = "email_production", user = "postgres", password= "postgres", port = "5432")
    @host = host
    @port = port
    @dbname = dbname
    @user = user
    @password = password
  end

  def connect
    PG.connect(
      host: @host,
      port: @port,
      dbname: @dbname,
      user: @user,
      password: @password
    )
  end
end
