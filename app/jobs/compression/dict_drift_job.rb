module Compression
  # Parent job that walks every active events segment and fans out one
  # DictTrainingJob per segment. Runs daily; the training jobs themselves
  # are gated by their own promotion threshold so most days end with zero
  # promotions. Transactions/spans don't compress and are skipped.
  class DictDriftJob
    def perform
      segments = Compression::IssuesEventsDict.distinct.pluck(:segment)

      Rails.logger.info "[DictDriftJob] fanning out #{segments.size} segment(s)"
      segments.each do |segment|
        Ingest::Tuber.put(
          Ingest::Tuber::MAINTENANCE_TUBE,
          {"class" => "Compression::DictTrainingJob", "args" => [segment]},
          con: 1
        )
      end
    end
  end
end
