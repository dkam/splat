set -e
dotnet build --nologo -v quiet -c Release -o out
for scenario in chained library_error message transaction; do
  SCENARIO=$scenario dotnet out/Checkout.dll
done
