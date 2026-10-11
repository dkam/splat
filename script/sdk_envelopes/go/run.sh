set -e
go build -o checkout .
for scenario in chained library_error message; do
  SCENARIO=$scenario ./checkout
done
