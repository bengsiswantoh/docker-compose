SELECT distinct(status) FROM _7e07a3cdfef1418ab69b496070068a3e.mail_log_statuses;
===
reject search in raw
zcat fluentd/logs/mail.log-20190101.gz | grep reject | grep -v NOQUEUE
===
bounced search in raw
zcat fluentd/logs/mail.log-20190101.gz | grep status=bounced | grep -v root | wc -l
zcat fluentd/logs/mail.log-20190101.gz | grep status=bounced | grep root | wc -l
===
sent search in raw
zcat fluentd/logs/mail.log-20190201.gz | grep status=sent | grep -v "127.0.0.1" | grep -v "dnetdummycb53162a@jasuindo.co.id" | grep -v "spamassassin" | wc -l
===
SELECT status.recipient, status.status, (status.log_time + interval '7 hour') as time, message.content
FROM _7e07a3cdfef1418ab69b496070068a3e.mail_log_statuses as status, _7e07a3cdfef1418ab69b496070068a3e.mail_log_messages as message
where status='sent'
and status.recipient != 'root@mail.jasuindo.co.id'
and status.recipient != 'dnetdummycb53162a@jasuindo.co.id'
and status.mail_log_message_id=message.id
order by time;

SELECT status.recipient, status.status, (status.log_time + interval '7 hour') as time, message.content
FROM _7e07a3cdfef1418ab69b496070068a3e.mail_log_statuses as status, _7e07a3cdfef1418ab69b496070068a3e.mail_log_messages as message
where status='deferred'
and status.recipient != 'root@mail.jasuindo.co.id'
and status.recipient != 'dnetdummycb53162a@jasuindo.co.id'
and status.mail_log_message_id=message.id
order by time;

SELECT status.recipient, status.status, (status.log_time + interval '7 hour') as time, message.content
FROM _7e07a3cdfef1418ab69b496070068a3e.mail_log_statuses as status, _7e07a3cdfef1418ab69b496070068a3e.mail_log_messages as message
where status='reject'
and status.recipient != 'root@mail.jasuindo.co.id'
and status.recipient != 'dnetdummycb53162a@jasuindo.co.id'
and status.mail_log_message_id=message.id
order by time;

SELECT status.recipient, status.status, (status.log_time + interval '7 hour') as time, message.content
FROM _first.mail_log_statuses as status, _first.mail_log_messages as message
where status='bounced'
and status.recipient != 'root@mail.jasuindo.co.id'
and status.recipient != 'dnetdummycb53162a@jasuindo.co.id'
and status.mail_log_message_id=message.id
order by time;
===
AND to_char((status.log_time + interval '7 hour'), 'YYYY-MM-DD HH24:MI') >= '2019-01-29 06:37'
AND to_char((status.log_time + interval '7 hour'), 'YYYY-MM-DD HH24:MI') <= '2019-01-30 06:50'
===
_first not inserted (mystery)
2019-01-11T06:54:52.628611+07:00 dnet-004181 postfix/smtp[8988]: 43bNCH3MZXz17dn: to=<root@mail.jasuindo.co.id>, relay=mail.jasuindo.co.id[45.64.4.181]:25, delay=1.1, delays=0.02/1.1/0.02/0, dsn=5.4.6, status=bounced (mail for mail.jasuindo.co.id loops back to myself)
