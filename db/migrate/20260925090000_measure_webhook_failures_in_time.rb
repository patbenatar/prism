# frozen_string_literal: true

# Two columns, both of which exist because the old give-up rule measured the
# wrong thing.
#
# `failing_since` — Prism used to stop watching a repository after twenty
# consecutive refusals. Twenty refusals is a count of *deliveries*, not of
# time, so how fast a subscription died depended on how busy its repository
# was: during one fourteen-hour token outage a busy repository burned through
# all twenty and was abandoned, while a quiet one on the same dead token spent
# six and recovered by itself. The more a repository was used, the sooner
# watching it gave up — exactly backwards. This column records when the
# current unbroken run of failures started, so the rule can ask how long we
# have been failing (WebhookSubscription::GIVE_UP_AFTER) instead.
#
# `failure_cause` — `broken` could not be revived by a new token, on the
# reasoning that "the thing that broke it was not the token". For a deleted
# repository that is true; for the failure that actually reaches this state it
# is false, and production held a subscription whose `broken_reason` said in
# so many words that GitHub had refused the token. The record has to say which
# kind of failure it was in a form code can read, not only in prose.
#
# The backfill is not a guess. The only thing that has ever moved a row out of
# `active` is WebhookSubscription#suspend!, reached from a 401, a 403, or the
# subscriber being signed out — all three of them things a person fixes by
# signing in. `abandon!`, the permanent one, has never had a caller. So every
# existing non-active row is `credential`, and its clock starts from whatever
# timestamp the row already carries.
#
# Note what this deliberately does *not* do: it does not change any row's
# status. A `broken` row stays broken until something actually proves the
# credential works again — a sign-in, or a re-registration. Flipping business
# state inside a migration would make that decision invisibly.
class MeasureWebhookFailuresInTime < ActiveRecord::Migration[8.1]
  def up
    add_column :webhook_subscriptions, :failing_since, :datetime
    add_column :webhook_subscriptions, :failure_cause, :string

    execute <<~SQL
      UPDATE webhook_subscriptions
         SET failure_cause = 'credential',
             failing_since = COALESCE(broken_at, last_failure_at, updated_at)
       WHERE status IN ('suspended', 'broken')
    SQL
  end

  def down
    remove_column :webhook_subscriptions, :failure_cause
    remove_column :webhook_subscriptions, :failing_since
  end
end
