set -e
dotnet build --nologo -v quiet -c Release -o out
for scenario in chained library_error message; do
  SCENARIO=$scenario dotnet out/Checkout.dll
done
