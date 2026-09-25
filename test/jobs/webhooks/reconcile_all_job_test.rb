# frozen_string_literal: true

require "test_helper"
require "fugit"

class Webhooks::ReconcileAllJobTest < ActiveJob::TestCase
  setup { @subscription = webhook_subscriptions(:docs_site) }

  test "queues a pass for every subscription still worth acting for" do
    suspended = webhook_subscriptions(:broken)
    suspended.suspend!("GitHub refused this account's token")

    assert_enqueued_jobs 2, only: Webhooks::ReconcileSubscriptionJob do
      Webhooks::ReconcileAllJob.perform_now
    end
  end

  # A suspension on a repository nobody opens pull requests in used to be
  # invisible to the give-up rule, because the rule only ever ran on a
  # delivery. This is what makes the clock run at the same rate everywhere.
  test "a suspended subscription is included, so the clock runs without deliveries" do
    @subscription.suspend!("GitHub refused this account's token")

    assert_enqueued_with job: Webhooks::ReconcileSubscriptionJob, args: [ @subscription.id ] do
      Webhooks::ReconcileAllJob.perform_now
    end
  end

  test "an abandoned subscription is left out" do
    webhook_subscriptions(:broken).abandon!("the repository is gone")

    Webhooks::ReconcileAllJob.perform_now

    assert_equal [ @subscription.id ],
                 enqueued_jobs.select { |job| job["job_class"] == "Webhooks::ReconcileSubscriptionJob" }
                              .map { |job| job["arguments"].first }
  end

  # Fanned out rather than done inline, so one repository that is rate
  # limiting or refusing us cannot stop the others being checked.
  test "each subscription gets its own job" do
    assert_enqueued_jobs 1, only: Webhooks::ReconcileSubscriptionJob do
      Webhooks::ReconcileAllJob.perform_now
    end
  end

  # A typo in the schedule is otherwise silent: nothing runs and nothing says
  # so until someone notices a link that never appeared.
  test "the recurring schedule names this job and parses" do
    config = Rails.application.config_for(:recurring)
    task = config[:reconcile_webhook_subscriptions]

    assert_equal "Webhooks::ReconcileAllJob", task[:class]
    assert Fugit.parse(task[:schedule]), "#{task[:schedule].inspect} is not a schedule Solid Queue can read"
  end
end
