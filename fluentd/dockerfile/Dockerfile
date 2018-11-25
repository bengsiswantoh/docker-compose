FROM fluent/fluentd:v1.1
MAINTAINER Bengsiswanto <mightiesthero@gmail.com>

RUN apk add --update --virtual .build-deps \
        sudo build-base ruby-dev \
        postgresql-dev

# customize following instruction as you wish
RUN sudo gem install \
        pg \
        redis \
        connection_pool

RUN sudo gem sources --clear-all \
 && rm -rf /var/cache/apk/* \
           /home/fluent/.gem/ruby/2.3.0/cache/*.gem
