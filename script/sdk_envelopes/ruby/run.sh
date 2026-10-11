set -e
gem install --silent --no-document sentry-ruby -v 7.0.0
for scenario in chained library_error message; do
  SCENARIO=$scenario ruby lib/checkout.rb
done
