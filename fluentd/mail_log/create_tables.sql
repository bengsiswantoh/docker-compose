CREATE SEQUENCE test.mail_logs_id_seq;

CREATE TABLE test.mail_logs
(
    id integer NOT NULL DEFAULT nextval('test.mail_logs_id_seq'::regclass),
    host character varying COLLATE pg_catalog."default",
    status character varying COLLATE pg_catalog."default",
    sender character varying COLLATE pg_catalog."default",
    recipient character varying COLLATE pg_catalog."default",
    size integer,
    process_start timestamp without time zone,
    process_end timestamp without time zone,
    queued_as character varying[] COLLATE pg_catalog."default" NOT NULL DEFAULT '{}'::character varying[],
    message_id character varying COLLATE pg_catalog."default",
    CONSTRAINT mail_logs_pkey PRIMARY KEY (id)
)
WITH (
    OIDS = FALSE
)
TABLESPACE pg_default;

CREATE SEQUENCE test.mail_log_messages_id_seq;

CREATE TABLE test.mail_log_messages
(
    id integer NOT NULL DEFAULT nextval('test.mail_log_messages_id_seq'::regclass),
    content character varying COLLATE pg_catalog."default",
    log_time timestamp without time zone NOT NULL,
    mail_log_id integer NOT NULL,
    CONSTRAINT mail_log_messages_pkey PRIMARY KEY (id),
    CONSTRAINT fk_rails_92894eb5b9 FOREIGN KEY (mail_log_id)
        REFERENCES test.mail_logs (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)
WITH (
    OIDS = FALSE
)
TABLESPACE pg_default;

CREATE SEQUENCE test.mail_log_statuses_id_seq;

CREATE TABLE test.mail_log_statuses
(
    id integer NOT NULL DEFAULT nextval('test.mail_log_statuses_id_seq'::regclass),
    mail_log_id integer,
    mail_log_message_id integer,
    recipient character varying COLLATE pg_catalog."default",
    status character varying COLLATE pg_catalog."default",
    log_time timestamp without time zone,
    CONSTRAINT mail_log_statuses_pkey PRIMARY KEY (id),
    CONSTRAINT fk_rails_0cc2d45952 FOREIGN KEY (mail_log_message_id)
        REFERENCES test.mail_log_messages (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_rails_ebdda5b121 FOREIGN KEY (mail_log_id)
        REFERENCES test.mail_logs (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)
WITH (
    OIDS = FALSE
)
TABLESPACE pg_default;
