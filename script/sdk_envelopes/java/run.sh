set -e
mvn -q -B compile dependency:build-classpath -Dmdep.outputFile=classpath.txt
for scenario in chained library_error message transaction; do
  SCENARIO=$scenario java -cp "target/classes:$(cat classpath.txt)" com.example.Checkout
done
