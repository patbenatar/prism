# frozen_string_literal: true

module Webhooks
  # The guarantee behind the fast path.
  #
  # A webhook delivery is the *quick* way to learn that a pull request
  # changed. It is not a reliable one: GitHub can only deliver to an address
  # that answers, with a token it accepts, into a process that is running, and
  # none of those is guaranteed. When one of them is false for a while — the
  # fourteen-hour token outage this class was written for — the events are
  # simply lost. GitHub does not redeliver them on its own and, before this
  # existed, nothing in Prism replayed them: a missed webhook was missed
  # permanently, and two pull requests went without their link for a day after
  # the token that caused it had already been fixed.
  #
  # So Prism stops depending on the events arriving. It asks GitHub what the
  # repository's open pull requests look like now and fixes whatever does not
  # match, exactly as if each of them had just produced an event. Announcer is
  # convergent by design — it asks "what should be true?", never "what
  # changed?" — so running it again over a pull request that is already right
  # is safe and cheap, and says so: `unchanged: link already correct`.
  #
  # Reconciliation is the guarantee. Webhooks are the latency.
  #
  # ## What a pass costs
  #
  # One call for the list of open pull requests, plus two for each pull
  # request it actually examines (that one's files, and its body read fresh
  # immediately before any write — see AnnouncementTarget::Description on why
  # that read cannot be cached).
  #
  # In the steady state it examines almost nothing, because `settled?` answers
  # from rows Prism already has without asking GitHub anything: a pass over a
  # healthy subscription is one call. After an outage it examines exactly the
  # pull requests that moved while Prism was deaf — the work that was missed,
  # and no more.
  #
  # Two bounds keep the bad case bounded:
  #
  # - **Only pull requests updated since the subscription was created.** Prism
  #   promises, in the words on the subscribe screen, to act on pull requests
  #   from the moment you start watching. Walking back over everything that
  #   was already open would edit descriptions nobody agreed to it editing —
  #   and it would be unbounded work on a repository with a long tail.
  # - **At most MAX_PULLS examined per pass.** The rest arrive on the next
  #   one; the list is newest-first, so the freshest are always taken first.
  class Reconciler
    # A quiet repository never reaches this. A repository with a genuine
    # backlog — a first pass after a long outage — spends 1 + 2×25 = 51 calls
    # against a 5,000/hour limit and finishes the rest two hours later.
    MAX_PULLS = 25

    Result = Data.define(:status, :detail, :examined, :changed)

    attr_reader :subscription

    def initialize(subscription:)
      @subscription = subscription
    end

    def call
      unless subscription.actable?
        return Result.new(status: :skipped, detail: "subscription is #{subscription.status}",
                          examined: 0, changed: 0)
      end

      candidates = pull_requests_to_examine
      changed = candidates.count { |pull| announce(pull) }

      Result.new(status: :reconciled,
                 detail: "examined #{candidates.size}, changed #{changed}",
                 examined: candidates.size, changed: changed)
    end

    private

    def pull_requests_to_examine
      pulls = client.pull_requests(subscription.owner, subscription.name, state: "open")

      # GitHub answered as this account, which is the same proof of life a
      # successful delivery gives. On a suspended subscription this is what
      # stops the give-up clock, and it is why that clock now runs at the same
      # rate on a quiet repository as on a busy one.
      subscription.mark_active!

      pulls.reject { |pull| out_of_scope?(pull) || settled?(pull) }.first(MAX_PULLS)
    end

    # Watching starts when you turn it on. A pull request that has not been
    # touched since then would never have produced a delivery either, so
    # announcing on it now would not be replaying a missed event — it would be
    # a new promise nobody made.
    def out_of_scope?(pull)
      pull.updated_at.blank? || pull.updated_at < subscription.created_at
    end

    # True when Prism has already answered for this pull request *in exactly
    # the state GitHub is showing now*, so looking again would buy nothing for
    # two GitHub calls.
    #
    # Equality against the `updated_at` we recorded, never an ordering against
    # a timestamp of our own. GitHub moves `updated_at` on every change to a
    # pull request — including the description edit an author makes when they
    # delete Prism's block, which is the one change this most needs to notice
    # — so "the same value we acted on" means "nothing has happened since",
    # with no assumption that Prism's clock and GitHub's agree. An earlier
    # version compared `last_event_at >= pull.updated_at`, and under clock
    # skew in one direction that silently skipped real changes.
    #
    # A pull request with no row, or a row from before this was recorded, is
    # unsettled and gets examined — which is also how a row settles for the
    # first time.
    def settled?(pull)
      announcement = announcements[pull.number]
      return false if announcement.nil?
      return true if announcement.declined?

      announcement.last_seen_updated_at.present? && announcement.last_seen_updated_at == pull.updated_at
    end

    # Queried rather than read off `subscription.pull_request_announcements`,
    # which caches: a pass that loaded an empty association would still see it
    # empty on the next pass, and re-examine every pull request it had just
    # settled.
    def announcements
      @announcements ||= PullRequestAnnouncement.where(webhook_subscription: subscription)
                                                .index_by(&:pull_request_number)
    end

    def announce(pull)
      Announcer.new(subscription: subscription, pull_request_number: pull.number,
                    seen_updated_at: pull.updated_at).call.changed?
    rescue Github::NotFound
      # One pull request can disappear, or stop being visible, while the
      # repository is fine — the delivery path leaves the subscription alone
      # for a 404 for the same reason. Repository-level refusals are not
      # caught here; they belong to the caller, which decides what they mean
      # for the subscription.
      false
    end

    # As the subscriber, always — the same identity the delivery path acts
    # under, so a link placed by reconciliation is indistinguishable from one
    # placed by a webhook. Asked for rather than built, so there is still
    # exactly one place that decides who Prism is on a watched repository.
    def client = @client ||= SubscriberClient.for(subscription)
  end
end
