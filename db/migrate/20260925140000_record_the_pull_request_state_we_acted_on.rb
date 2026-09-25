# frozen_string_literal: true

# Reconciliation decides whether a pull request still needs looking at by
# comparing what Prism last did against what GitHub last did. The first
# version of that comparison was `announcement.last_event_at >= pull.updated_at`
# — our clock against GitHub's.
#
# That only holds while the two clocks agree, which is not something Prism
# controls or can assert. If ours runs ahead, an author's edit landing inside
# the skew window gets a GitHub `updated_at` that is still earlier than our
# `last_event_at`, the pull request reads as settled, and **a real change is
# skipped** until something else happens to touch it. That is precisely the
# silent-miss failure this whole workstream exists to remove, reintroduced one
# layer up. (Skew the other way is merely wasteful: everything is re-examined
# every pass and lands on `unchanged`.)
#
# Storing the `updated_at` we actually observed, and testing it for equality,
# removes the window rather than narrowing it. There is no ordering and no
# clock: either GitHub's value is the one we already acted on, or it is not.
#
# Existing rows start null, which reads as "not settled" — so the first pass
# after this deploys re-examines the pull requests Prism already knows about,
# records what it saw, and settles them. One bounded catch-up, by design.
class RecordThePullRequestStateWeActedOn < ActiveRecord::Migration[8.1]
  def change
    add_column :pull_request_announcements, :last_seen_updated_at, :datetime
  end
end
