set -e
npm install --silent --no-audit --no-fund --no-package-lock
for scenario in chained library_error message; do
  SCENARIO=$scenario node checkout.js
done
