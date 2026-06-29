# frozen_string_literal: true

# Countless pagination: skips the `SELECT COUNT(*)` that regular Pagy runs on
# every page load. On the logs table (~1M rows on the meta instance) that count
# alone cost ~7s per request. Countless instead fetches `limit + 1` rows to
# learn whether a next page exists — enough for prev/next nav on an append-only
# log feed, with no count query at all.
require "pagy/extras/countless"
