# frozen_string_literal: true

require "test_helper"

# Guards the seam between "building the image" and "starting the app".
#
# `docker build` boots RAILS_ENV=production — that is what `assets:precompile`
# does — with no runtime configuration present at all. Nothing else in this app
# ever does that, so a boot-time check that demands runtime config is invisible
# to a green test suite and fatal to the image, and you find out during the
# release rather than before it.
#
# The rule that resolves it: a check that guards *serving traffic* must not fire
# while *compiling assets*. SECRET_KEY_BASE_DUMMY is the signal Rails itself
# sets to mean "this boot will never serve a request", so it is the condition
# used. These tests pin both halves — the exemption exists, and it is narrow.
class BuildBootTest < ActiveSupport::TestCase
  # Comments explain the flag; only executable lines can widen the exemption.
  def code_in(path)
    Rails.root.join(path).read.lines.reject { |l| l.strip.start_with?("#") }.join
  end

  test "application.rb only waives SECRET_KEY_BASE for a dummy build" do
    source = code_in("config/application.rb")

    assert_match(/Rails\.env\.production\? && ENV\["SECRET_KEY_BASE_DUMMY"\]\.blank\?/, source,
      "the waiver must be conjoined with production, not replace the production check")

    # If this grows a second occurrence, the one case where a production boot
    # without a real secret is tolerated is being widened, and that needs
    # saying out loud rather than slipping in.
    assert_equal 1, source.scan("SECRET_KEY_BASE_DUMMY").size,
      "exactly one build-time exemption, or the guard is being widened"
  end

  test "the Dockerfile precompiles with the dummy flag, not a fake secret" do
    source = Rails.root.join("Dockerfile").read

    assert_match(/SECRET_KEY_BASE_DUMMY=1 \.\/bin\/rails assets:precompile/, source)
    refute_match(/SECRET_KEY_BASE=1 /, source,
      "SECRET_KEY_BASE=1 satisfies the guard by faking a secret; the point is to signal that this boot never serves")
  end

  test "the Dockerfile declares GIT_SHA in the stage that uses it" do
    stage = Rails.root.join("Dockerfile").read.split(/^FROM /)[2]

    # An ARG is only in scope for the stage that declares it. Declared before
    # the FROM, --build-arg is silently ignored and every deploy reports
    # "unknown" — a failure with no error message attached to it.
    assert_match(/ARG GIT_SHA=unknown/, stage, "GIT_SHA must be declared inside the build stage")
    assert_match(/RUN echo "\$\{GIT_SHA\}" > VERSION/, stage)
  end

  # A leftover `config.<framework>` from the Rails template raises NoMethodError
  # the moment production boots, once whatever provided it goes away —
  # solid_queue is the usual one, left behind by a move to another queue.
  #
  # Checked against what is actually loaded rather than against the Gemfile:
  # config/application.rb requires "rails/all", so Active Storage and friends
  # are present without ever being named as gems, and a Gemfile grep would
  # report them missing.
  FRAMEWORK_CONSTANTS = {
    "solid_queue" => "SolidQueue",
    "active_storage" => "ActiveStorage",
    "action_mailbox" => "ActionMailbox",
    "action_text" => "ActionText"
  }.freeze

  test "production only configures frameworks this app actually loads" do
    source = code_in("config/environments/production.rb")

    FRAMEWORK_CONSTANTS.each do |setting, constant|
      next if Object.const_defined?(constant)

      refute_match(/^\s*config\.#{setting}[.\s]/, source,
        "production.rb configures #{setting}, but #{constant} is not loaded — production will not boot")
    end
  end

  test "the revision is always answerable" do
    assert Rails.application.config.x.revision.present?
  end
end
