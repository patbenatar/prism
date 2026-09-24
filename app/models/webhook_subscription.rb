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
  #              retries, and a success puts it back to `active`.
  #   broken     Genuinely over: we gave up after MAX_CONSECUTIVE_FAILURES
  #              consecutive refusals. Nothing but re-adding revives it.
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

  # How many consecutive refusals before we stop. Generous on purpose: each
  # one costs a single GitHub call on a delivery that was arriving anyway, and
  # any success resets it, so the only thing this protects against is a token
  # nobody ever comes back to fix. A repository that is actually deleted stops
  # delivering on its own, because the hook dies with it.
  MAX_CONSECUTIVE_FAILURES = 20

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

  scope :active, -> { where(status: ACTIVE) }
  scope :suspended, -> { where(status: SUSPENDED) }
  # Everything a delivery should still be attempted for.
  scope :working, -> { where(status: [ ACTIVE, SUSPENDED ]) }
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

  # GitHub refused us over something a person can fix. Records why, counts it,
  # and keeps the subscription in play — the next delivery will try again.
  #
  # Only after MAX_CONSECUTIVE_FAILURES in a row do we conclude that nobody is
  # coming to fix it and stop.
  def suspend!(reason)
    failures = consecutive_failures.to_i + 1

    update!(
      status: failures >= MAX_CONSECUTIVE_FAILURES ? BROKEN : SUSPENDED,
      broken_reason: reason.to_s.truncate(500),
      broken_at: Time.current,
      last_failure_at: Time.current,
      consecutive_failures: failures
    )
  end

  # Stop for good, for a failure that a retry cannot help.
  def abandon!(reason)
    update!(status: BROKEN, broken_reason: reason.to_s.truncate(500), broken_at: Time.current,
            last_failure_at: Time.current)
  end

  # GitHub accepted us. Clears the failure history so an old, fixed problem
  # cannot add itself to a new one and trip the give-up threshold.
  def mark_active!
    return self if active? && consecutive_failures.to_i.zero?

    update!(status: ACTIVE, broken_reason: nil, broken_at: nil, consecutive_failures: 0)
    self
  end

  # Called when a fresh token lands for this user. Only revives what was
  # suspended: a subscription we gave up on stays given up on, because the
  # thing that broke it was not the token.
  def revive_after_new_token!
    mark_active! if suspended?
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

  def announcement_for(pull_request_number)
    pull_request_announcements.find_or_initialize_by(pull_request_number: pull_request_number)
  end
end
