class IssuesEventsRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :issues_events, reading: :issues_events }
end
