FROM jekyll/builder:latest

RUN gem install bundler
RUN rm -rf ~/.bundle/cache

COPY . /site
RUN chmod ugo+rwx /site
WORKDIR /site

RUN bundle install

EXPOSE 4000

USER 1000

ENTRYPOINT ["bundle", "exec"]

