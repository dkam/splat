class TransactionsSpansRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :transactions_spans, reading: :transactions_spans }
end
