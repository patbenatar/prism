# frozen_string_literal: true

require "test_helper"

class PinnedRepoTest < ActiveSupport::TestCase
  setup { @user = users(:prism_dev) }

  test "requires an owner and a name" do
    pin = PinnedRepo.new(user: @user)

    assert_not pin.valid?
    assert_includes pin.errors.attribute_names, :owner
    assert_includes pin.errors.attribute_names, :name
  end

  test "a repo can only be pinned once per user" do
    @user.pinned_repos.create!(owner: "acme", name: "docs-site")
    dupe = @user.pinned_repos.build(owner: "acme", name: "docs-site")

    assert_not dupe.valid?
  end

  test "the same owner/name can be pinned by two different users" do
    other = users(:octocat)
    @user.pinned_repos.create!(owner: "acme", name: "docs-site")

    pin = other.pinned_repos.build(owner: "acme", name: "docs-site")

    assert pin.valid?
  end

  test "position is assigned in pin order and never overwritten" do
    first = @user.pinned_repos.create!(owner: "acme", name: "docs-site")
    second = @user.pinned_repos.create!(owner: "prism-dev", name: "scratchpad")

    assert_operator second.position, :>, first.position

    first.update!(name: "docs-site") # re-saving must not reassign position
    assert_equal first.position, first.reload.position
  end

  test "partition sorts pinned repos by pin order and leaves the rest in GitHub's order" do
    docs = Github::Types::Repo.new(id: 1, owner: "acme", name: "docs-site", full_name: "acme/docs-site",
                                    private: true, description: nil, default_branch: "main",
                                    pushed_at: Time.current, open_issues_count: 0, html_url: "x",
                                    owner_avatar_url: "x", owner_type: "Organization")
    scratch = Github::Types::Repo.new(id: 2, owner: "prism-dev", name: "scratchpad",
                                       full_name: "prism-dev/scratchpad", private: false, description: nil,
                                       default_branch: "main", pushed_at: Time.current, open_issues_count: 0,
                                       html_url: "x", owner_avatar_url: "x", owner_type: "User")
    other = Github::Types::Repo.new(id: 3, owner: "acme", name: "other", full_name: "acme/other",
                                     private: false, description: nil, default_branch: "main",
                                     pushed_at: Time.current, open_issues_count: 0, html_url: "x",
                                     owner_avatar_url: "x", owner_type: "Organization")

    # Pinned second, so it should still sort ahead of `docs` in the pinned list.
    @user.pinned_repos.create!(owner: "acme", name: "docs-site")
    @user.pinned_repos.create!(owner: "prism-dev", name: "scratchpad")

    pinned, rest = PinnedRepo.partition([ docs, scratch, other ], @user)

    assert_equal [ docs, scratch ], pinned
    assert_equal [ other ], rest
  end

  test "partition drops a pin whose repo isn't in the fetched page" do
    only_repo = Github::Types::Repo.new(id: 1, owner: "prism-dev", name: "scratchpad",
                                         full_name: "prism-dev/scratchpad", private: false, description: nil,
                                         default_branch: "main", pushed_at: Time.current, open_issues_count: 0,
                                         html_url: "x", owner_avatar_url: "x", owner_type: "User")
    @user.pinned_repos.create!(owner: "acme", name: "gone-now")

    pinned, rest = PinnedRepo.partition([ only_repo ], @user)

    assert_empty pinned
    assert_equal [ only_repo ], rest
  end
end
