# frozen_string_literal: true

require "test_helper"

class PullRequestsHelperTest < ActionView::TestCase
  Author = Github::Types::Author

  # The helper reads `current_user`, which a controller supplies through
  # helper_method; in a view test there is no controller doing that.
  attr_accessor :current_user

  setup { self.current_user = users(:prism_dev) }

  test "the author of a pull request is recognised whatever the login's casing" do
    assert own_pull_request?(pull_by("prism-dev"))
    assert own_pull_request?(pull_by("Prism-Dev")), "GitHub logins are case-insensitive"
  end

  test "someone else's pull request is not your own" do
    refute own_pull_request?(pull_by("hubot"))
  end

  # A deleted account's pull request comes back with no author. Nobody can be
  # its author, so every decision stays on offer and GitHub has the last word.
  test "a pull request with no author, or no signed-in user, is nobody's own" do
    refute own_pull_request?(Struct.new(:author).new(nil))
    refute own_pull_request?(nil)

    self.current_user = nil
    refute own_pull_request?(pull_by("prism-dev"))
  end

  private

  def pull_by(login)
    Struct.new(:author).new(Author.new(login: login, avatar_url: nil, html_url: nil))
  end
end
