# frozen_string_literal: true

# Helpers shared by every screen. Anything specific to pull requests lives in
# PullRequestsHelper.
module ApplicationHelper
  GITHUB_HOST = "https://github.com"

  # A person's GitHub profile. The account menu and every author byline link
  # here, so the login is the only thing we need to store to point at someone.
  def github_profile_url(login)
    "#{GITHUB_HOST}/#{login}"
  end

  # A <time> element showing "3 days ago" with the exact timestamp in its
  # tooltip. Relative time is what a reviewer actually wants ("is this stale?");
  # the absolute time is one hover away when it matters.
  #
  #   relative_time(pr.updated_at)                  → "3 days ago"
  #   relative_time(pr.created_at, prefix: "opened") → "opened 3 days ago"
  def relative_time(time, prefix: nil)
    return nil if time.blank?

    time = Time.zone.parse(time.to_s) unless time.respond_to?(:strftime)
    return nil if time.blank?

    words = "#{time_ago_in_words(time)} ago"
    words = "#{prefix} #{words}" if prefix.present?

    tag.time words,
             datetime: time.iso8601,
             title: time.strftime("%-d %b %Y at %H:%M UTC"),
             class: "whitespace-nowrap"
  end

  # HTML that came from GitHub — a rendered PR description, a comment's
  # `bodyHTML`, a Markdown preview — on its way into a view.
  #
  # Nothing GitHub sends is trusted: a comment body is attacker-controlled
  # text, and GitHub's own sanitization is not a boundary we rely on.
  # Markdown::Sanitizer is the single safelist for every piece of foreign HTML.
  def github_html(html)
    return nil if html.blank?

    raw Markdown::Sanitizer.call(html)
  end

  # GitHub's reaction names are REST-style strings ("+1", "hooray"); this is the
  # glyph that goes on the reaction pill. The pill always carries an sr-only
  # name alongside it, so the emoji is decorative.
  REACTION_EMOJI = {
    "+1" => "\u{1F44D}", "-1" => "\u{1F44E}", "laugh" => "\u{1F604}",
    "confused" => "\u{1F615}", "heart" => "\u{2764}\u{FE0F}", "hooray" => "\u{1F389}",
    "rocket" => "\u{1F680}", "eyes" => "\u{1F440}"
  }.freeze

  def reaction_emoji(content)
    REACTION_EMOJI.fetch(content.to_s, "\u{1F44D}")
  end

  # "12 minutes" from a count of seconds. `Github::RateLimited#retry_in` gives
  # us the wait directly, which beats deriving it from a reset timestamp: when
  # GitHub sends a retry-after header it is the authoritative number.
  def duration_in_words(seconds)
    seconds = seconds.to_i
    return "a moment" if seconds < 5

    distance_of_time_in_words(0, seconds)
  end

  # "in about 12 minutes" — the fallback for a rate-limit reset when all we have
  # is the timestamp it lifts at.
  def relative_time_until(time)
    return "shortly" if time.blank?

    time = Time.zone.parse(time.to_s) unless time.respond_to?(:strftime)
    return "shortly" if time.blank? || time <= Time.current

    "in #{distance_of_time_in_words(Time.current, time)}"
  end

  # Inline style for a GitHub label pill. GitHub stores the label color as a
  # bare hex ("d73a4a") and leaves the text color to the client, so we compute
  # one that passes contrast against it: white on dark labels, near-black on
  # light ones. Those two are tokens (`--color-on-light` / `--color-on-dark`)
  # but they are deliberately NOT theme-aware — the fill underneath them is
  # the repository's own colour and does not change when the page does.
  #
  # The border is the label's hue pulled 18% toward the page's ink, which is
  # the only part that has to know about the theme: on paper that darkens a
  # pale yellow label so it doesn't dissolve into a white panel, and on the
  # dark canvas the same expression lightens a near-black label so it doesn't
  # dissolve into the panel there. Ruby can't know which mode is on screen, so
  # the mixing is left to CSS.
  def label_pill_style(hex)
    rgb = parse_hex(hex) || [ 0x8b, 0x94, 0x9e ]
    text = relative_luminance(rgb) > 0.42 ? "--color-on-light" : "--color-on-dark"
    border = "color-mix(in oklab, #{rgb_css(rgb)} 82%, var(--color-ink))"

    "background-color: #{rgb_css(rgb)}; color: var(#{text}); border-color: #{border};"
  end

  # "+128 −7" with the two numbers colored by what they mean. Used on file rows
  # and PR rows wherever a diffstat belongs.
  def diffstat(additions, deletions)
    tag.span class: "tnum inline-flex items-center gap-1.5 text-xs" do
      safe_join([
        tag.span("+#{additions.to_i}", class: "text-added"),
        tag.span("−#{deletions.to_i}", class: "text-removed")
      ])
    end
  end

  # Pluralize without the count being repeated by callers: `count_of(3, "file")`
  # → "3 files". Keeps row metadata terse and consistent.
  def count_of(count, singular, plural = nil)
    "#{number_with_delimiter(count.to_i)} #{(count.to_i == 1 ? singular : (plural || singular.pluralize))}"
  end

  private

  def parse_hex(hex)
    digits = hex.to_s.delete("#").strip
    digits = digits.chars.flat_map { |c| [ c, c ] }.join if digits.length == 3
    return nil unless digits.match?(/\A\h{6}\z/)

    digits.scan(/../).map { |pair| pair.to_i(16) }
  end

  def rgb_css(rgb) = format("#%02x%02x%02x", *rgb)

  # WCAG relative luminance — the same number that drives the contrast ratios
  # recorded in DESIGN.md §2.
  def relative_luminance(rgb)
    channels = rgb.map do |value|
      c = value / 255.0
      c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4)
    end

    (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
  end
end
