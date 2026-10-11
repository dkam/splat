set -e
composer install --quiet --no-interaction --no-progress
for scenario in chained library_error message; do
  SCENARIO=$scenario php checkout.php
done
