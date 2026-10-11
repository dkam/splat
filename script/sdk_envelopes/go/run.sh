set -e
go build -o checkout .
for scenario in chained library_error message transaction; do
  SCENARIO=$scenario ./checkout
done
