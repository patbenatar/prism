# frozen_string_literal: true

# Building GitHub webhook deliveries by hand.
#
# A delivery is three headers and a raw JSON body, and the signature is over
# the *bytes* of that body — so these helpers keep the body as a string from
# the moment it is signed to the moment it is posted. Re-encoding it anywhere
# in between would change the whitespace and every signature test would pass
# for the wrong reason.
module WebhookHelpers
  DEFAULT_REPO = "acme/docs-site"
  DEFAULT_REPO_ID = 900_001

  # The subset of a real pull_request payload that Webhooks::Payload reads,
  # plus enough around it to look like the real thing.
  def pull_request_event(action: "opened", number: 42, repo: DEFAULT_REPO, repo_id: DEFAULT_REPO_ID)
    {
      "action" => action,
      "number" => number,
      "pull_request" => {
        "number" => number,
        "node_id" => "PR_kwDOABCD12MAAAABc9Vk",
        "state" => "open",
        "title" => "Rewrite the getting-started guide",
        "body" => "Tightens the prose.",
        "html_url" => "https://github.com/#{repo}/pull/#{number}"
      },
      "repository" => {
        "id" => repo_id,
        "name" => repo.split("/").last,
        "full_name" => repo,
        "owner" => { "login" => repo.split("/").first }
      },
      "sender" => { "login" => "hubot" }
    }
  end

  def ping_event(repo: DEFAULT_REPO, repo_id: DEFAULT_REPO_ID)
    {
      "zen" => "Non-blocking is better than blocking.",
      "hook_id" => 555,
      "repository" => { "id" => repo_id, "full_name" => repo }
    }
  end

  # PRISM_PUBLIC_URL is read from the environment because it is deployment
  # configuration, not application config — which makes this the only way to
  # set it in a test. Restored afterwards; the suite forks per worker, so a
  # leak would only poison one process, which is worse than poisoning all of
  # them because it would be intermittent.
  def with_public_url(url = "https://prism.test")
    original = ENV["PRISM_PUBLIC_URL"]
    set_public_url(url)
    yield
  ensure
    set_public_url(original)
  end

  def set_public_url(url)
    if url.nil?
      ENV.delete("PRISM_PUBLIC_URL")
    else
      ENV["PRISM_PUBLIC_URL"] = url
    end
  end

  def webhook_signature(body, secret)
    "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
  end

  # Posts a delivery. `signature:` takes :valid (sign it properly), :missing
  # (omit the header) or any string to send verbatim.
  def deliver_webhook(payload,
                      secret:,
                      event: "pull_request",
                      delivery_id: SecureRandom.uuid,
                      signature: :valid,
                      path: github_webhook_path)
    body = payload.is_a?(String) ? payload : payload.to_json

    headers = { "CONTENT_TYPE" => "application/json" }
    headers["X-GitHub-Event"] = event if event
    headers["X-GitHub-Delivery"] = delivery_id if delivery_id

    case signature
    when :valid then headers["X-Hub-Signature-256"] = webhook_signature(body, secret)
    when :missing then nil
    else headers["X-Hub-Signature-256"] = signature
    end

    post path, params: body, headers: headers
    body
  end
end
