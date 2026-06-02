module Compression
  # Parent job that walks every active segment across both compression
  # dictionary stores and fans out one DictTrainingJob per segment. Runs
  # daily; the training jobs themselves are gated by their own promotion
  # threshold so most days end with zero promotions.
  class DictDriftJob
    def perform
      segments = []
      Compression::IssuesEventsDict.distinct.pluck(:segment).each      { |s| segments << [:issues_events, s] }
      Compression::TransactionsSpansDict.distinct.pluck(:segment).each { |s| segments << [:transactions_spans, s] }

      Rails.logger.info "[DictDriftJob] fanning out #{segments.size} segment(s)"
      segments.each do |(_db, segment)|
        Ingest::Tuber.put(
          Ingest::Tuber::MAINTENANCE_TUBE,
          { "class" => "Compression::DictTrainingJob", "args" => [segment] },
          con: 1
        )
      end
    end
  end
end
