require "application_system_test_case"

# The card order is the one piece of the index that lives in JavaScript, so an
# integration test of #reorder proves only half of it. This drives the real
# browser through the keyboard path, which exercises the same Stimulus
# controller, the same fetch (CSRF header included) and the same endpoint as a
# drag — everything but the native drag events themselves, which Selenium
# can't synthesise in Chrome.
class ProjectReorderingTest < ApplicationSystemTestCase
  setup do
    Rails.cache.clear
    Project.reorder_by_slugs!(["project-one", "project-two"])
  end

  test "moving a card with the keyboard persists the new order" do
    visit root_path
    assert_equal ["project-one", "project-two"], rendered_slugs

    find("[data-slug='project-one'] [data-sortable-target='handle']").send_keys(:arrow_right)

    assert_equal ["project-two", "project-one"], rendered_slugs
    # The save is a background fetch, so wait for the server to have it rather
    # than reading the DB the instant the DOM moves.
    assert_equal ["project-two", "project-one"], eventually_persisted_slugs
  end

  test "the new order survives a reload" do
    visit root_path
    find("[data-slug='project-one'] [data-sortable-target='handle']").send_keys(:arrow_right)
    assert_equal ["project-two", "project-one"], eventually_persisted_slugs

    visit root_path

    assert_equal ["project-two", "project-one"], rendered_slugs
  end

  test "a card at the end of the row will not move past it" do
    visit root_path

    find("[data-slug='project-two'] [data-sortable-target='handle']").send_keys(:arrow_right)

    assert_equal ["project-one", "project-two"], rendered_slugs
    assert_equal ["project-one", "project-two"], Project.ordered.pluck(:slug)
  end

  private

  def rendered_slugs
    all("[data-sortable-target='item']").map { |item| item[:"data-slug"] }
  end

  def eventually_persisted_slugs
    20.times do
      slugs = Project.ordered.pluck(:slug)
      return slugs if slugs != ["project-one", "project-two"]
      sleep 0.1
    end
    Project.ordered.pluck(:slug)
  end
end
