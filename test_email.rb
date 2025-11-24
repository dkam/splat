#!/usr/bin/env ruby

puts 'Testing email delivery...'

project = Project.first || Project.create!(name: 'Test Project')
issue = Issue.create!(
  title: 'Test Issue for Email',
  fingerprint: "test::fingerprint::#{Time.now.to_i}",
  project: project,
  status: :open,
  first_seen: Time.current,
  last_seen: Time.current
)

puts 'New issue email sent! Check your browser for the email preview.'

# Test issue reopening
puts 'Testing issue reopening...'
issue.update!(status: :resolved)
sleep 1
issue.update!(status: :open)
puts 'Issue reopened email sent! Check your browser for the email preview.'