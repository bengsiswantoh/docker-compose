require "pg"

class MyPG
  def initialize
    @host = "localhost"
    @port = "5432"
    @dbname = "email_development"
    @user = "postgres"
    @password = "postgres"
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
