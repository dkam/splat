# frozen_string_literal: true

namespace :splat do
  desc "Recompute Issue#count from events. Run once after enabling counter_cache to fix any drift."
  task recount_issues: :environment do
    batch_size = 500
    total = Issue.count
    processed = 0

    Issue.in_batches(of: batch_size) do |batch|
      batch.update_all(
        "count = (SELECT COUNT(*) FROM events WHERE events.issue_id = issues.id)"
      )
      processed += batch.size
      puts "Recounted #{processed}/#{total} issues"
    end

    puts "Done."
  end
end
