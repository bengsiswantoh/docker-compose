require "time"

class MyParser
  # rejected and has no queue
  NOQUEUE_EMAIL = 0

  # relay=127.0.0.1[127.0.0.1]:10026
  ANTI_VIRUS = 1

  # relay=spamassassin
  SPAM_ASSASSIN = 2

  # relay=#{email_server}
  PROCESS_EMAIL = 3

  # relay=127.0.0.1[127.0.0.1]:10027
  WHITELIST = 4

  # relay=dreamavis.dwp.net.id[45.64.4.191]:10024
  AMAVIS = 5

  def initialize(logger, redis, pg, schema)
    @logger = logger
    @redis = redis
    @pg = pg
    @schema = schema

    redis_expire_hours = 27 * 7
    @redis_expire_time = redis_expire_hours * 3600

    @table_mail_logs = "mail_logs"
    @table_mail_log_messages = "mail_log_messages"
    @table_mail_log_statuses = "mail_log_statuses"
  end

  def process(line, data)
    @logger.info line

    key = data["key"]

    # generate redis key
    redis_key = redis_key_of(@schema, key)

    # merge with information build from message
    record = build_record(data, redis_key)

    if key != "NOQUEUE"
      save_to_redis(redis_key, record)
    end

    # if queue removed, save to postgres
    if record && record["removed"] && validate_data(record)
      # @logger.info "set #{redis_key} => #{ record.to_json }"

      save_to_db(record, redis_key)

      # delete from redis
      # @redis.del(redis_key)
    end
  end

  def build_record(data, redis_key)
    key = data["key"]

    record = {
      "key" => key,
      "removed" => false,
      "schema" => @schema,
      "host" => data["host"]
    }

    # set step to NOQUEUE
    if key == "NOQUEUE"
      record["step"] = NOQUEUE_EMAIL
      record["removed"] = true
    else
      # get data from redis
      redis_data = @redis.get(redis_key)
      record = JSON.parse(redis_data) if redis_data
    end

    time = Time.parse(data["ltime"]).to_s
    record["time"] = time if !record["time"] || (record["time"] && time < record["time"])

    message = data["message"]

    # search from
    result = message.match(/from=<(?<from>[^>]*)>/)
    if result && !record["from"]
      record["from"] = result["from"]
    end

    # search subject
    # step ANTI_VIRUS
    # result = message.match(/Subject: (?<subject>.*) from /)
    # record["subject"] = result["subject"] if result

    # search queued as
    # step ANTI_VIRUS
    result = message.match(/queued as (?<queued>[^\)]*)/)
    record["queued_as"] = result["queued"] if result

    # search message-id
    # step ANTI_VIRUS can be empty string so message-id optional
    # step SPAM_ASSASSIN and step PROCESS_EMAIL
    result = message.match(/message-id=<?(?<id>[^>]*)>?/)
    record["message_id"] = result["id"] if result

    record["recipients"] ||= {}
    record["details"] ||= {}

    # search relay, to and status
    result = message.match(/to=<(?<to>[^>]*)>.* relay=(?<relay>[^,]*).* status=(?<status>[^ ]*) \((?<message>[^\)]*)/)
    if result
      status = result["status"]

      if result["relay"].match(/dreamavis.dwp.net.id/)
        record["step"] = AMAVIS
        status = "virus" if result["message"].match(/BOUNCE/)
      end

      if result["relay"] == "127.0.0.1[127.0.0.1]:10026"
        record["step"] = ANTI_VIRUS
        status = "virus" if result["message"] == "250 Virus Detected; Discarded Email"
      elsif result["relay"] == "127.0.0.1[127.0.0.1]:10027"
        record["step"] = WHITELIST
      elsif result["relay"] == "spamassassin"
        record["step"] = SPAM_ASSASSIN
      else
        record["step"] = PROCESS_EMAIL if !record["step"]

        ignored_relays = ["autoreply", "archivefilter", "webhook"]
        ignored_relay = ignored_relays.include?(result["relay"])
      end

      if record["step"] != PROCESS_EMAIL
        record["recipients"][result["to"]] = build_recipient(time, message, status, result["relay"])
        if status == "virus"
          record["details"][result["to"]] = build_recipient(time, message, status, result["relay"])
        end
        record["removed"] = true
      else
        if !ignored_relay
          record["details"][result["to"]] = build_recipient(time, message, status, result["relay"])
          record["removed"] = true
        end
      end

    end

    # REJECT AND NOQUEUE
    result = message.match(/(?<status>reject|discard):.* to=<(?<to>[^>]*)>/)
    if result || key == "NOQUEUE"
      record["recipients"][result["to"]] = build_recipient(time, message, result["status"])
      record["details"][result["to"]] = build_recipient(time, message, result["status"])

      record["removed"] = true
      record["step"] = ANTI_VIRUS if !record["step"]
    end

    # queue: removed
    # step ANTI_VIRUS, step SPAM_ASSASSIN, and step PROCESS_EMAIL
    record["removed"] = true if message == "#{key}: removed"

    record
  end

  def redis_key_of(schema, key)
    "log-#{schema}-#{key}"
  end

  def build_recipient(time, message, status, relay = nil)
    recipient = {}
    recipient["saved"] = false
    recipient["time"] = time
    recipient["message"] = message
    recipient["status"] = status
    recipient["relay"] = relay if relay

    recipient
  end

  def validate_data(record)
    return true if [SPAM_ASSASSIN, PROCESS_EMAIL].include?(record["step"]) && record["message_id"]
    return true if [NOQUEUE_EMAIL, ANTI_VIRUS, WHITELIST, AMAVIS].include?(record["step"])

    false
  end

  def save_to_redis(redis_key, record)
    # save to redis
    @redis.set(redis_key, record.to_json)
    # set expire time
    @redis.expire(redis_key, @redis_expire_time)
  end

  ##
  # Save record from redis to postgres
  def save_to_db(record, redis_key)
    case record["step"]
    when NOQUEUE_EMAIL
      recipients = parse_recipients(record)
      to = recipients.join(",")
      queued_as = [ record["key"] ]

      data = [ record["host"], record["from"], to, format_time_db(record["time"]), parse_array_to_pg(queued_as), "" ]

      query = "SELECT id FROM #{@schema}.#{@table_mail_logs} WHERE host=$1 AND sender=$2 AND recipient=$3 AND process_start=$4 AND queued_as=$5 AND message_id=$6"
      pg_row = execute_and_return(query, data)
      if !pg_row
        query = "INSERT INTO #{@schema}.#{@table_mail_logs} (host, sender, recipient, process_start, queued_as, message_id) VALUES ($1, $2, $3, $4, $5, $6) returning id"
        pg_row = execute_and_return(query, data, true)
      end
      mail_log_id = pg_row["id"]

      record["details"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail, record, redis_key)
      end

    when ANTI_VIRUS, AMAVIS, SPAM_ASSASSIN, WHITELIST
      record["message_id"] = "" if !record["message_id"]

      mail_log_id = insert_log(record)

      record["details"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail, record, redis_key)
      end

    when PROCESS_EMAIL
      mail_log_id = insert_log(record)

      record["details"].each do |to, detail|
        insert_message_status(mail_log_id, to, detail, record, redis_key)
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
    if record["queued_as"] && record["queued_as"].length > 0
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

      query = "UPDATE #{@schema}.#{@table_mail_logs} SET host=$1, sender=$2, recipient=$3, process_start=$4, queued_as=$5, message_id=$6 WHERE id=$7 returning id"
      data = [ pg_row["id"] ]
    else
      query = "INSERT INTO #{@schema}.#{@table_mail_logs} (host, sender, recipient, process_start, queued_as, message_id) VALUES ($1, $2, $3, $4, $5, $6) returning id"
      data = []
    end

    data = [ host, from, to, time, parse_array_to_pg(queued_as), message_id ] + data
    result = execute_and_return(query, data, true)
    result["id"]
  end

  ##
  # Insert into message and status
  def insert_message_status(mail_log_id, to, detail, record, redis_key)
    # insert mail log messages
    mail_log_message_id = insert_message(mail_log_id, detail)

    # insert/update mail log statuses
    insert_status(mail_log_id, mail_log_message_id, to, detail, record, redis_key)
  end

  ##
  # Insert into mail_log_messages
  def insert_message(mail_log_id, detail)
    time = format_time_db(detail["time"])

    data = [ mail_log_id, detail["message"], time ]
    pg_row = search_message(data)
    if !pg_row
      query = "INSERT INTO #{@schema}.#{@table_mail_log_messages} (mail_log_id, content, log_time) VALUES ($1, $2, $3) returning id"
      pg_row = execute_and_return(query, data, true)
    end

    pg_row ? pg_row["id"] : false
  end

  ##
  # Insert into mail_log_statuses
  def insert_status(mail_log_id, mail_log_message_id, to, detail, record, redis_key)
    if !detail["saved"]
      key = record["key"]
      time = format_time_db(detail["time"])

      data = [ mail_log_id, to, key ]
      pg_row = search_status(data)
      data = [ detail["status"], detail["relay"], time, mail_log_message_id, key]
      if pg_row
        query = "UPDATE #{@schema}.#{@table_mail_log_statuses} SET status=$1, relay=$2, log_time=$3, mail_log_message_id=$4, queue_id=$5 WHERE id=#{pg_row["id"]} returning id"
      else
        data = [ mail_log_id, to ] + data
        query = "INSERT INTO #{@schema}.#{@table_mail_log_statuses} (mail_log_id, recipient, status, relay, log_time, mail_log_message_id, queue_id) "
        query += "VALUES ($1, $2, $3, $4, $5, $6, $7) returning id"
      end

      result = execute_and_return(query, data, true) if query
      if result
        detail["saved"] = true
        save_to_redis(redis_key, record)
      end
    end
  end

  ##
  # Parse recipients get key
  def parse_recipients(record)
    record["recipients"].map { |to, detail| to }
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
    query = "SELECT id, recipient, process_start, queued_as, message_id FROM #{@schema}.#{@table_mail_logs} WHERE '#{params[:key]}'=ANY(queued_as) "
    query += "OR '#{params[:message_id]}'=message_id " if params[:message_id]
    query += "OR '#{params[:queued_as]}'=ANY(queued_as) " if params[:queued_as]
    # query += "AND queued_as <> '{}' "
    query += "ORDER BY id DESC "

    execute_and_return(query, data)
  end

  ##
  # Search mail log message
  def search_message(data)
    query = "SELECT id FROM #{@schema}.#{@table_mail_log_messages} WHERE mail_log_id=$1 AND content=$2 AND log_time=$3"
    execute_and_return(query, data)
  end

  ##
  # Search mail log status
  def search_status(data)
    query = "SELECT id FROM #{@schema}.#{@table_mail_log_statuses} WHERE mail_log_id=$1 AND recipient=$2 AND queue_id=$3"
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
      @logger.info "#{query} #{data}" if print

      # execute query using transaction
      @pg.transaction do |transaction|
        result = transaction.exec(query, data)
      end

    rescue => err
      @logger.fatal "#{err} #{query} #{data}"
    end
  end
end
