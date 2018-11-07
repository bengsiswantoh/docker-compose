##
# helps:
# http://docs.fluentd.org/v0.12/articles/plugin-development#writing-buffered-output-plugins
# https://github.com/uken/fluent-plugin-postgres/blob/master/lib/fluent/plugin/out_postgres.rb

require 'fluent/plugin/output'

class Fluent::DreamsFailedAuthOutput < Fluent::Plugin::Output
  # First, register the plugin. NAME is the name of this plugin
  # and identifies the plugin in the configuration file.
  Fluent::Plugin.register_output('dreams_failed_auth', self)

  # config_param defines a parameter. You can refer a parameter via @path instance variable
  # Without :default, a parameter is required.
  config_param :host, :string
  config_param :database, :string
  config_param :schema, :string
  config_param :port, :integer, default: 5432
  config_param :username, :string, default: nil
  config_param :password, :string, default: nil, secret: true

  config_param :pg_pool_size, :integer, default: 5
  config_param :pg_pool_timeout, :integer, default: 60

  config_param :rabbitmq_host, :string, default: 'localhost'
  config_param :rabbitmq_username, :string, default: 'guest'
  config_param :rabbitmq_password, :string, default: 'guest'

  attr_accessor :pg_conn

  def initialize
    super
    require "pg"
    require "redis"
    require "connection_pool"
  end

  ##
  # This method is called before starting.
  # 'conf' is a Hash that includes configuration parameters.
  # If the configuration is invalid, raise Fluent::ConfigError.
  def configure(conf)
    super

    unless PG::Connection.escape_string(@schema) == @schema
      fail Fluent::ConfigError, "not safe schema name"
    end

    # try pg connection
    begin
      self.pg_conn = self.pg_config
      self.pg_conn.with do |conn|
        log.info conn
      end
    rescue => e
      fail Fluent::ConfigError, "#{e.class} #{e.message}"
    end
  end

  # This method is called when starting.
  # Open sockets or files and create a thread here.
  def start
    super
    # my own start-up code
  end

  # This method is called when shutting down.
  def shutdown
    # close postgres connection
    self.pg_conn.shutdown { |conn| conn.close }

    super
  end

  ##
  # method for sync buffered output mode
  def write(chunk)
    # for standard chunk format (without #format method)
    chunk.each do |time, data|
      log.info "receive #{Time.at(time)}, #{data}"

      save_log(data)
    end
  end

  ##
  # postgres connection
  def pg_config
    # connect to postgresql server
    ConnectionPool.new(size: @pg_pool_size, timeout: @pg_pool_timeout) {
      PG.connect(
        host: @host,
        port: @port,
        dbname: @database,
        user: @username,
        password: @password
      )
    }
  end

  def save_log(data)
    result = data["message"].match(/\[(?<ip>[^\]]*)/)
    ip = result["ip"]
    time = format_time_db(data["ltime"])

    data = [ data["host"], data["process"], ip, time ]

    if !search_log(data)
      query = "INSERT INTO #{@schema}.failed_logins (host, process, ip_address, created_at) VALUES ($1, $2, $3, $4)"
      execute_query(query, data, true)
    end
  end

  ##
  # Search mail logs
  def search_log(data)
    query = "SELECT id FROM #{@schema}.failed_logins WHERE host=$1 AND process=$2 AND ip_address=$3 AND created_at=$4 "
    query += "ORDER BY id DESC "

    execute_and_return(query, data)
  end

  ##
  # Format database time
  def format_time_db(time)
    Time.parse(time).utc.strftime("%Y-%m-%d %H:%M:%S")
  end

  ##
  # execute query and return first data
  def execute_and_return(query, data, print = false)
    result = execute_query(query, data, print)
    result && result.ntuples > 0 ? result.first : false
  end

  ##
  # Execute sql query
  def execute_query(query, data, print = false)
    begin
      log.info "#{query} #{data}" if print

      # execute query using transaction
      self.pg_conn.with do |conn|
        conn.transaction do |transaction|
          result = transaction.exec(query, data)
        end
      end

    rescue => err
      log.fatal "#{err} #{query} #{data}"
    end
  end
end