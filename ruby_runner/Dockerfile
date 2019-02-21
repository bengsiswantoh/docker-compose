FROM ruby:2.5

RUN apt-get update && apt-get install libpq-dev -y

WORKDIR /usr/src/app

COPY Gemfile Gemfile.lock ./
RUN bundle install

CMD ["irb"]
