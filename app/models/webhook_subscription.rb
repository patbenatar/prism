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

  STATUSES = %w[active broken].freeze

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

  scope :active, -> { where(status: "active") }
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

  def active? = status == "active"

  def broken? = status == "broken"

  # Stop acting as this user on this repository. Called when GitHub tells us the
  # token is dead or the account lost access — retrying either would burn rate
  # limit forever and never succeed, because nothing about the failure is
  # transient.
  def mark_broken!(reason)
    update!(status: "broken", broken_reason: reason.to_s.truncate(500), broken_at: Time.current)
  end

  def mark_active!
    update!(status: "active", broken_reason: nil, broken_at: nil)
  end

  # The token can be revoked without anyone telling us; User#revoke_token!
  # clears it the moment GitHub answers 401 anywhere in the app.
  def actable? = active? && user&.token?

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
