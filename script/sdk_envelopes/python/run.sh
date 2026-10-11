set -e
pip install --quiet --disable-pip-version-check --root-user-action=ignore -r requirements.txt
for scenario in chained library_error message; do
  SCENARIO=$scenario python checkout.py
done
