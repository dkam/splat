# frozen_string_literal: true

# Ruby's error_highlight appends the offending line and a caret row to an
# exception's message, so one can run to several lines:
#
#   undefined local variable or method 'job' for main
#
#           job.perform
#           ^^^
#
# The first line is the message proper, and is what a heading, a list row, an
# email subject or an HTTP header can hold. The rest is code, shown as code.
module ExceptionMessage
  module_function

  def headline(text)
    text.to_s.strip.lines.first.to_s.strip
  end

  # The lines after the headline, with their shared indent removed so the
  # carets stay under the code they point at. Nil for a one-line message.
  def detail(text)
    text.to_s.strip.lines.drop(1).join.strip_heredoc.sub(/\A\s*\n/, "").rstrip.presence
  end
end
