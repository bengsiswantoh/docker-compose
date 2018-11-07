##
# helps:
# http://docs.fluentd.org/v0.12/articles/plugin-development#writing-buffered-output-plugins
# https://github.com/uken/fluent-plugin-postgres/blob/master/lib/fluent/plugin/out_postgres.rb

require 'fluent/plugin/output'

class Fluent::DreamsLogOutput < Fluent::Plugin::Output
  # First, register the plugin. NAME is the name of this plugin
  # and identifies the plugin in the configuration file.
  Fluent::Plugin.register_output('dreams_log', self)

  # rejected and has no queue
  NOQUEUE_EMAIL = 0

  # get email header from this process from, to, and subject
  INCOMING_EMAIL = 1

  # SPAM_ASSASSIN is a requeue, this process generate message-id if email message-id empty
  SPAM_ASSASSIN = 2

  # PROCESS_EMAIL is delivery status including autoforward and detail from alias
  PROCESS_EMAIL = 3

  # bounce email status
  BOUNCE_EMAIL = 4

  # ignored email
  IGNORED_EMAIL = 10

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

  config_param :redis_host, :string, default: 'localhost'
  config_param :redis_port, :integer, default: 6379
  config_param :redis_db, :integer, default: 1
  config_param :redis_pass, :string, default: nil
  config_param :redis_expire_hours, :integer, default: 27

  config_param :redis_pool_size, :integer, default: 5
  config_param :redis_pool_timeout, :integer, default: 1

  attr_accessor :pg_conn
  attr_accessor :redis_conn
  attr_accessor :redis_expire_time

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

    self.redis_expire_time = @redis_expire_hours * 3600

    # try redis connection
    begin
      self.redis_conn = self.redis_config
      self.redis_conn.with do |conn|
        log.info conn.ping
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

    # close redis connection
    self.redis_conn.shutdown { |conn| conn.quit }

    super
  end

  ##
  # method for sync buffered output mode
  def write(chunk)
    # for standard chunk format (without #format method)
    chunk.each do |time, data|
      log.info "receive #{Time.at(time)}, #{data}"

      key = data["key"]
      record = nil

      if key != "NOQUEUE"
        # generate redis key
        redis_key = redis_key_of(key)

        # get data from redis
        self.redis_conn.with do |conn|
          record = conn.get(redis_key)
        end
      end

      if !record
        record = {
          "schema" => @schema,
          "removed" => false,
          "key" => key,
          "host" => data["host"]
        }
      else
        record = JSON.parse(record)
      end

      # merge with information build from message
      record = build_record(record, data)

      if key != "NOQUEUE"
        self.redis_conn.with do |conn|
          # save to redis
          conn.set(redis_key, record.to_json)
          # set expire time
          conn.expire(redis_key, self.redis_expire_time)
        end
      end

      # if queue removed, save to postgres
      if record && record["removed"] && validate_data(record)
        # log.info "set #{redis_key} => #{ record.to_json }"

        save_to_db(record)

        # delete from redis
        # self.redis_conn.with do |conn|
        #  conn.del(redis_key)
        # end
      end
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

  ##
  # redis connection
  def redis_config
    # config redis server
    ConnectionPool.new(size: @redis_pool_size, timeout: @redis_pool_timeout) {
      Redis.new({
        host: @redis_host,
        port: @redis_port,
        db: @redis_db,
        password: @redis_pass
      })
    }
  end

  ##
  # redis-key by key
  def redis_key_of(key)
    "log-#{@schema}-#{key}"
  end

  ##
  # search information from message
  def build_record(record, data)
    message = data["message"]
    time = Time.parse(data["ltime"]).to_s

    record["time"] = time if !record["time"] || (record["time"] && time < record["time"])

    # search from
    result = message.match(/from=<(?<from>[^>]*)>/)
    if result && !record["from"]
      record["from"] = result["from"]
      # set step to bounce email
      record["step"] = BOUNCE_EMAIL if result["from"] == ""
    end

    # set step to NOQUEUE
    if data["key"] == "NOQUEUE"
      record["step"] = NOQUEUE_EMAIL
      record["removed"] = true
    end

    # set step to IGNORED_EMAIL
    result = message.match(/uid=0/)
    record["step"] = IGNORED_EMAIL if result

    record["recipients"] ||= {}
    record["rejects"] ||= {}

    # search subject
    # step INCOMING_EMAIL
    # result = message.match(/Subject: (?<subject>.*) from /)
    # record["subject"] = result["subject"] if result

    # search queued as
    # step INCOMING_EMAIL
    result = message.match(/queued as (?<queued>[^\)]*)/)
    record["queued_as"] = result["queued"] if result

    # search message-id
    # step INCOMING_EMAIL can be empty string so message-id optional
    # step SPAM_ASSASSIN and step PROCESS_EMAIL
    result = message.match(/message-id=<?(?<id>[^>]*)>?/)
    record["message_id"] = result["id"] if result

    # search relay, to and status
    # step INCOMING_EMAIL, step SPAM_ASSASSIN, and step PROCESS_EMAIL
    result = message.match(/to=<(?<to>[^>]*)>.* relay=(?<relay>[^,]*).* status=(?<status>[^ ]*)/)
    if result
      # TODO check relay none, webhook
      if result["relay"].match(/127.0.0.1/)
        # set step to INCOMING_EMAIL
        record["step"] = INCOMING_EMAIL
      elsif result["relay"].match(/spamassassin/)
        # set step to SPAM_ASSASSIN
        record["step"] = SPAM_ASSASSIN
      else
        record["step"] = PROCESS_EMAIL if !record["step"]
      end

      record["recipients"][result["to"]] = build_recipient(time, message, result["status"], result["relay"])
    end

    # REJECT
    result = message.match(/(?<status>reject|discard):.* to=<(?<to>[^>]*)>/)
    if result
      record["rejects"][result["to"]] = build_recipient(time, message, result["status"])
      if !message.match(/Recipient address rejected:/)
        record["removed"] = true
        record["step"] = INCOMING_EMAIL
      end
    end

    # queue: removed
    # step INCOMING_EMAIL, step SPAM_ASSASSIN, and step PROCESS_EMAIL
    record["removed"] = true if message == "#{data["key"]}: removed"

    record
  end

  def build_recipient(time, message, status, relay = nil)
    recipient = {}
    recipient["time"] = time
    recipient["message"] = message
    recipient["status"] = status
    recipient["relay"] = relay if relay

    recipient
  end

  def validate_data(record)
    return true if record["step"] == INCOMING_EMAIL && record["from"]
    return true if [SPAM_ASSASSIN, PROCESS_EMAIL].include?(record["step"]) && record["message_id"]
    return true if [NOQUEUE_EMAIL, BOUNCE_EMAIL, IGNORED_EMAIL].include?(record["step"])

    false
  end

  ##
  # Save record from redis to postgres
  def save_to_db(record)
    case record["step"]
    when NOQUEUE_EMAIL
      recipients = parse_recipients(record)
      to = recipients.join(",")
      queued_as = [ record["key"] ]

      data = [ record["host"], record["from"], to, format_time_db(record["time"]), parse_array_to_pg(queued_as), "" ]

      query = "SELECT id FROM #{@schema}.mail_logs WHERE host=$1 AND sender=$2 AND recipient=$3 AND process_start=$4 AND queued_as=$5 AND message_id=$6"
      pg_row = execute_and_return(query, data)
      if !pg_row
        query = "INSERT INTO #{@schema}.mail_logs (host, sender, recipient, process_start, queued_as, message_id) VALUES ($1, $2, $3, $4, $5, $6) returning id"
        pg_row = execute_and_return(query, data, true)
      end
      mail_log_id = pg_row["id"]

      record["rejects"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail)
      end

    when BOUNCE_EMAIL
      mail_log_id = insert_log(record)

      record["recipients"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail)
      end

    when INCOMING_EMAIL
      record["message_id"] = "" if !record["message_id"]

      mail_log_id = insert_log(record)

      record["recipients"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail, false)
      end

      # ini untuk yang reject yang ada queue lanjutannya
      record["rejects"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail)
      end

    when SPAM_ASSASSIN
      mail_log_id = insert_log(record)

      # TODO check case is message and status need to inserted to db
      # record["recipients"].each do |to, detail|
      #   # insert mail log messages
      #   insert_messages(mail_log_id, detail)
      # end

    when PROCESS_EMAIL
      mail_log_id = insert_log(record)

      record["recipients"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail)
      end

    end

  end

  ##
  # Insert or update mail log
  def insert_log(record)
    message_id = record["message_id"]
    host = record["host"]
    from = record["from"]
    time = format_time_db(record["time"])
    recipients = parse_recipients(record)
    to = recipients.join(",")

    params = { key: record["key"] }
    queued_as = [ record["key"] ]

    params[:message_id] = message_id if message_id && message_id.length > 0
    if record["queued_as"]
      params[:queued_as] = record["queued_as"]
      queued_as << record["queued_as"]
    end

    pg_row = search_log(params)
    # insert/update mail logs
    if pg_row
      # add recipients
      if pg_row["recipient"]
        pg_recipients = pg_row["recipient"].split(',')
        pg_recipients += recipients
        to = pg_recipients.uniq.join(",")
      end

      queued_as += parse_pg_to_array(pg_row, "queued_as")
      message_id = pg_row["message_id"] if message_id == ""

      # check with current time
      time = pg_row["process_start"] if pg_row["process_start"] != nil && pg_row["process_start"] < time

      query = "UPDATE #{@schema}.mail_logs SET host=$1, sender=$2, recipient=$3, process_start=$4, queued_as=$5, message_id=$6 WHERE id=$7 returning id"
      data = [ pg_row["id"] ]
    else
      query = "INSERT INTO #{@schema}.mail_logs (host, sender, recipient, process_start, queued_as, message_id) VALUES ($1, $2, $3, $4, $5, $6) returning id"
      data = []
    end

    data = [ host, from, to, time, parse_array_to_pg(queued_as), message_id ] + data
    result = execute_and_return(query, data, true)
    result["id"]
  end

  ##
  # Insert into message and status
  def insert_message_status(mail_log_id, to, detail, update = true)
    # insert mail log messages
    mail_log_message_id = insert_message(mail_log_id, detail)

    # insert/update mail log statuses
    insert_status(mail_log_id, mail_log_message_id, to, detail, update)
  end

  ##
  # Insert into mail_log_messages
  def insert_message(mail_log_id, detail)
    time = format_time_db(detail["time"])

    data = [ mail_log_id, detail["message"], time ]
    pg_row = search_message(data)
    if !pg_row
      query = "INSERT INTO #{@schema}.mail_log_messages (mail_log_id, content, log_time) VALUES ($1, $2, $3) returning id"
      pg_row = execute_and_return(query, data, true)
    end

    pg_row ? pg_row["id"] : false
  end

  ##
  # Insert into mail_log_statuses
  def insert_status(mail_log_id, mail_log_message_id, to, detail, update = true)
    time = format_time_db(detail["time"])

    data = [ mail_log_id, to ]
    pg_row = search_status(data)
    data = [ detail["status"], time, mail_log_message_id ]
    if pg_row
      query = "UPDATE #{@schema}.mail_log_statuses SET status=$1, log_time=$2, mail_log_message_id=$3 WHERE id=#{pg_row["id"]}" if update
    else
      data = [ mail_log_id, to ] + data
      query = "INSERT INTO #{@schema}.mail_log_statuses (mail_log_id, recipient, status, log_time, mail_log_message_id) VALUES ($1, $2, $3 ,$4, $5)"
    end
    execute_query(query, data, true)
  end

  ##
  # Parse recipients get key
  def parse_recipients(record)
    record["recipients"].map { |to, detail| to } + record["rejects"].map { |to, detail| to }
  end

  ##
  # Parse pg field array to array
  def parse_pg_to_array(pg_row, field_name)
    return [] if !pg_row || !pg_row[field_name]

    pg_row[field_name].gsub("{", "")
      .gsub("}", "")
      .split(",")
  end

  ##
  # Parse array to pg field array
  def parse_array_to_pg(arr)
    "{#{arr.uniq.join(",")}}"
  end

  ##
  # Search mail logs
  def search_log(params)
    data = []
    query = "SELECT id, recipient, process_start, queued_as, message_id FROM #{@schema}.mail_logs WHERE '#{params[:key]}'=ANY(queued_as) "
    query += "OR '#{params[:message_id]}'=message_id " if params[:message_id]
    query += "OR '#{params[:queued_as]}'=ANY(queued_as) " if params[:queued_as]
    query += "ORDER BY id DESC "

    execute_and_return(query, data)
  end

  ##
  # Search mail log message
  def search_message(data)
    query = "SELECT id FROM #{@schema}.mail_log_messages WHERE mail_log_id=$1 AND content=$2 AND log_time=$3"
    execute_and_return(query, data)
  end

  ##
  # Search mail log status
  def search_status(data)
    query = "SELECT id FROM #{@schema}.mail_log_statuses WHERE mail_log_id=$1 AND recipient=$2"
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
