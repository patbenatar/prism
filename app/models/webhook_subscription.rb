# frozen_string_literal: true

# A repository Prism watches, and the account it acts as when it does.
#
# **This does not break principle 1.** PLAN.md says GitHub is the only source
# of truth and Prism persists nothing of GitHub's. A subscription is not
# GitHub's data: it is *Prism's own configuration* — which repositories this
# installation was asked to watch, whose token to use when it acts, and the
# secret we generated for the hook. None of it is a copy of anything GitHub
# owns, and none of it can go stale against GitHub, because GitHub does not
# have an opinion about it. The one GitHub-side identifier we keep, `hook_id`,
# is a handle we created and must be able to delete again.
#
# The pull request itself — its title, body, files, whether it has Markdown —
# is still fetched fresh from GitHub on every delivery and never stored.
class WebhookSubscription < ApplicationRecord
  # The same crown-jewel treatment as users.access_token: anyone holding this
  # secret can forge a delivery that makes Prism edit a pull request.
  encrypts :secret

  belongs_to :user
  has_many :webhook_deliveries, dependent: :destroy
  has_many :pull_request_announcements, dependent: :destroy

  # Three states, and the middle one is the point.
  #
  #   active     GitHub last accepted us.
  #   suspended  GitHub last refused us, over something a person can fix —
  #              almost always a token. **It still acts.** The next delivery
  #              or reconciliation pass retries, and a success puts it back to
  #              `active`.
  #   broken     Genuinely over: it has been failing for longer than
  #              GIVE_UP_AFTER without a single success.
  #
  # This used to be two states with `broken` as a one-way door, and that was
  # the wrong shape. The commonest failure by far is a token GitHub refuses
  # once; the owner signs in again, the new token works, and under the old
  # design nothing ever looked again. Watching a repository has to survive
  # that without anyone noticing, so the recovery is automatic on both sides:
  # the next delivery retries (see Webhooks::ProcessDeliveryJob) and a fresh
  # token revives it immediately (see User).
  ACTIVE = "active"
  SUSPENDED = "suspended"
  BROKEN = "broken"
  STATUSES = [ ACTIVE, SUSPENDED, BROKEN ].freeze

  # Why we stopped, in the one form that matters: can the person who set this
  # up make it work again?
  #
  #   credential  GitHub refused this account — a revoked token, an org that
  #               withdrew its approval, a subscriber signed out of Prism.
  #               Replacing the credential is proof the refusal is over, so
  #               these come back on the next sign-in however long they sat.
  #   permanent   Nothing a credential can reach: the repository is gone.
  #               Only re-adding it starts over.
  #
  # `broken` used to be unreachable by a new token whatever the cause, on the
  # reasoning that "the thing that broke it was not the token". That reasoning
  # is right about a deleted repository and wrong about every failure that
  # actually reaches this state.
  CREDENTIAL = "credential"
  PERMANENT = "permanent"
  FAILURE_CAUSES = [ CREDENTIAL, PERMANENT ].freeze

  # How long a subscription may go on failing before Prism stops trying.
  #
  # This used to be a count — twenty consecutive refusals — and a count
  # measures the wrong thing. Refusals arrive on deliveries, so the count is
  # really a measure of how busy the repository is: in one fourteen-hour token
  # outage a busy repository spent all twenty and was abandoned while a quiet
  # one on the same dead token spent six and recovered by itself. The more a
  # repository was used, the faster watching it died, which is backwards —
  # those are the ones that matter most.
  #
  # Time is what the rule was always reaching for: "nobody is coming back to
  # fix this". Thirty days of unbroken failure is that, and it no longer
  # depends on traffic, because Webhooks::ReconcileAllJob retries every
  # working subscription on a schedule whether or not a single pull request
  # was opened. A quiet repository and a busy one now get the same thirty days.
  GIVE_UP_AFTER = 30.days

  # Stored in GitHub's own casing, because owner/name end up in a link a human
  # reads. GitHub itself is case-insensitive about them and will deliver
  # "Owner/Repo" for a hook registered on "owner/repo", so every lookup and the
  # uniqueness index go through lower().
  normalizes :owner, with: ->(value) { value.to_s.strip }
  normalizes :name, with: ->(value) { value.to_s.strip }

  validates :owner, presence: true
  validates :name, presence: true, uniqueness: { scope: :owner, case_sensitive: false }
  validates :secret, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :failure_cause, inclusion: { in: FAILURE_CAUSES }, allow_nil: true

  scope :active, -> { where(status: ACTIVE) }
  scope :suspended, -> { where(status: SUSPENDED) }
  # Everything a delivery or a reconciliation pass should still be attempted
  # for.
  scope :working, -> { where(status: [ ACTIVE, SUSPENDED ]) }
  # Everything a fresh credential is evidence for. Suspended rows by
  # definition; abandoned ones only when a credential is what broke them.
  scope :revivable, -> { where(status: SUSPENDED).or(where(status: BROKEN, failure_cause: CREDENTIAL)) }
  scope :named, ->(owner, name) {
    where("lower(owner) = ? AND lower(name) = ?", owner.to_s.downcase, name.to_s.downcase)
  }

  # GitHub's hook secret. 32 bytes of entropy, hex-encoded, which is what
  # GitHub's own documentation suggests and comfortably exceeds the 32 bytes
  # SHA-256 consumes.
  def self.generate_secret = SecureRandom.hex(32)

  # Matched on the repository's numeric id first so a rename on GitHub doesn't
  # orphan the subscription, then on owner/name for rows registered before we
  # learned the id.
  def self.for_repository(github_repo_id, full_name)
    by_id = where(github_repo_id: github_repo_id).first if github_repo_id.present?
    return by_id if by_id

    owner, _, name = full_name.to_s.partition("/")
    return nil if owner.blank? || name.blank?

    named(owner, name).first
  end

  def full_name = "#{owner}/#{name}"

  def active? = status == ACTIVE

  def suspended? = status == SUSPENDED

  def broken? = status == BROKEN

  # GitHub refused us over something a person can fix. Records why, starts (or
  # continues) the clock, and keeps the subscription in play — the next
  # delivery or reconciliation pass will try again.
  #
  # Only once that clock passes GIVE_UP_AFTER do we conclude that nobody is
  # coming to fix it and stop. `consecutive_failures` is still counted, but as
  # a diagnostic: it says how hard we tried, not when to stop.
  def suspend!(reason, cause: CREDENTIAL)
    started = failing_since || Time.current
    give_up = Time.current >= started + GIVE_UP_AFTER
    attempts = consecutive_failures.to_i + 1

    update!(
      status: give_up ? BROKEN : SUSPENDED,
      failure_cause: cause,
      failing_since: started,
      broken_reason: give_up ? give_up_reason(reason, started, attempts) : reason.to_s.truncate(500),
      # Only set when we actually gave up. It used to be stamped on every
      # refusal, which made "broken_at" mean "last failed" on a row that was
      # not broken at all.
      broken_at: give_up ? Time.current : nil,
      last_failure_at: Time.current,
      consecutive_failures: attempts
    )
  end

  # Why watching stopped, written so the row alone still answers it.
  #
  # `webhook_deliveries` is a debugging aid with a fortnight's retention, and
  # we give up at thirty days — so by the time anyone asks "why did this
  # stop?", every delivery that could have told them has been pruned. The
  # answer therefore has to live on the subscription, which nothing prunes.
  # `failing_since`, `broken_at` and `consecutive_failures` each hold a piece
  # of it; this is the sentence that puts them together, because the reason is
  # what the screen shows and what a `pp` of the row shows first.
  def give_up_reason(reason, started, attempts)
    "#{reason.to_s.truncate(300)} Prism gave up after #{GIVE_UP_AFTER.inspect} of continuous failure — " \
      "failing since #{started.utc.strftime('%Y-%m-%d %H:%M UTC')}, " \
      "#{attempts} attempt#{'s' unless attempts == 1}, none accepted.".truncate(500)
  end
  private :give_up_reason

  # Stop for good, for a failure that no credential can reach.
  def abandon!(reason)
    update!(status: BROKEN, failure_cause: PERMANENT, failing_since: failing_since || Time.current,
            broken_reason: reason.to_s.truncate(500), broken_at: Time.current,
            last_failure_at: Time.current)
  end

  # GitHub accepted us. Clears the failure history — including the clock — so
  # an old, fixed problem cannot add itself to a new one and trip the give-up
  # threshold early.
  def mark_active!
    return self if active? && consecutive_failures.to_i.zero? && failing_since.nil?

    update!(status: ACTIVE, broken_reason: nil, broken_at: nil, failing_since: nil,
            failure_cause: nil, consecutive_failures: 0)
    self
  end

  # A fresh credential is evidence about exactly one class of failure — but it
  # is conclusive about that class, whether we were still retrying or had
  # already given up. The old rule revived only `suspended`, which left
  # production holding a subscription whose recorded reason was "GitHub
  # refused this account's token" and which a working token could not reach.
  def revivable_by_credential? = suspended? || (broken? && failure_cause == CREDENTIAL)

  # Called when a fresh token lands for this user.
  def revive_after_new_token!
    mark_active! if revivable_by_credential?
  end

  # `suspended` is deliberately included: a suspended subscription is exactly
  # one we should keep trying. `broken` is not.
  #
  # The token can also be revoked without anyone telling us; User#revoke_token!
  # clears it the moment GitHub answers 401 anywhere in the app.
  def actable? = !broken? && user&.token?

  # GitHub is still POSTing to an address Prism no longer answers on.
  #
  # In development this happens whenever the tunnel's hostname changes, so
  # yesterday's subscription points GitHub at a URL that no longer resolves;
  # claiming ngrok's free static domain makes it rare rather than daily. It
  # fails *silently* — GitHub keeps trying, nothing arrives, and there is
  # nothing in Prism's logs to look at, because the request never reaches us.
  # Hence a visible state on the subscriptions screen rather than a line in a
  # runbook.
  #
  # False when we cannot tell: an unset PRISM_PUBLIC_URL is its own, louder
  # warning, and a row registered before this column existed has nothing to
  # compare against.
  def callback_stale?
    current = Webhooks::CallbackUrl.current_or_nil
    return false if current.nil? || callback_url.blank?

    callback_url != current
  end

  # Deliberately *not* `pull_request_announcements.find_or_initialize_by`.
  #
  # Building through the association puts the new, unsaved row into the
  # association's target, and Active Record autosaves those the next time the
  # parent is saved. So an announcement Prism had not decided anything about
  # yet got written to the database by an unrelated `update!` on the
  # subscription — in practice by suspend!, in the rescue that ran *because*
  # the GitHub call had raised. The result was rows claiming `state: "absent"`
  # with `last_event_at: nil`: a record of an outcome that never happened, and
  # indistinguishable afterwards from a pull request Prism genuinely retracted
  # from.
  #
  # The bookkeeping is all-or-nothing instead. A row exists only once the
  # Announcer has committed to an outcome and written it (placed!/retracted!/
  # decline!), which is the only point at which there is anything true to
  # record. Nothing needs a fourth "we have seen this pull request but never
  # announced on it" state: no reader would act on it differently from the
  # absence of a row, and Webhooks::Reconciler treats both the same way — as a
  # pull request still to look at.
  def announcement_for(pull_request_number)
    pull_request_announcements.find_by(pull_request_number: pull_request_number) ||
      PullRequestAnnouncement.new(webhook_subscription: self, pull_request_number: pull_request_number)
  end
end
