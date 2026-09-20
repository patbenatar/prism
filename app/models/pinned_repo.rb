# frozen_string_literal: true

# A user's preference that one of their repositories should sort to the top
# of /repos. This is the first thing Prism persists that isn't a user or a
# token, and it is deliberately *not* a violation of PLAN.md principle 1
# ("GitHub is the only source of truth"): a pin stores no fact about the
# repository itself (not its description, visibility, push time, nothing
# GitHub could tell us) — only which owner/name pair this Prism user, on this
# Prism install, would like to see first. If GitHub renamed or deleted the
# repository, or revoked the token's access to it, the pin would simply stop
# matching anything the next time /repos is fetched (PinnedRepo.partition
# only surfaces a pin for a repo that's actually in the fetched page) and
# nothing about the repo's own state was ever cached here. Don't "fix" this by
# deleting it as a principle violation — it isn't one.
class PinnedRepo < ApplicationRecord
  belongs_to :user

  validates :owner, presence: true
  validates :name, presence: true, uniqueness: { scope: %i[user_id owner] }

  before_validation :assign_position, on: :create

  scope :ordered, -> { order(:position) }

  # Splits a page of Github::Types::Repo (as fetched for /repos) into
  # [pinned, rest]. `pinned` is ordered by the user's pin position and
  # silently drops any pin whose repo isn't in `repos` — a stale pin (renamed,
  # deleted, access revoked) degrades to simply not showing, never to a
  # guess. `rest` is `repos` minus whatever ended up in `pinned`, in GitHub's
  # own order.
  def self.partition(repos, user)
    position_by_key = user.pinned_repos.ordered.pluck(:owner, :name).each_with_index.to_h

    pinned = repos.select { |repo| position_by_key.key?([ repo.owner, repo.name ]) }
                  .sort_by { |repo| position_by_key[[ repo.owner, repo.name ]] }

    [ pinned, repos - pinned ]
  end

  private

  def assign_position
    self.position ||= (user.pinned_repos.maximum(:position) || 0) + 1
  end
end
