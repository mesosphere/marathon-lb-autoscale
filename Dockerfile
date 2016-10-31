FROM ruby:2-slim

COPY    Gemfile /marathon-lb-autoscale/
WORKDIR /marathon-lb-autoscale
RUN     bundle install
COPY    autoscale.rb /marathon-lb-autoscale/

ENTRYPOINT [ "/marathon-lb-autoscale/autoscale.rb" ]
CMD        []
