set -e
cargo build --release --quiet
for scenario in chained library_error message; do
  SCENARIO=$scenario target/release/checkout
done
