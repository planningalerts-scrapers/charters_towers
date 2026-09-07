#!/usr/bin/env ruby
# frozen_string_literal: true

# Scrapes development applications for Charters Towers Regional Council.
#
# The council lists applications on its OpenCities (Granicus) website, one
# page per year. Pages from 2022 onwards have one accordion per application,
# with a heading of "REF - ADDRESS" and a body paragraph of
# "REF - DESCRIPTION - ADDRESS". Older pages (2017-2021) are flat lists of
# decision notice PDFs; records are extracted from those when the link text
# includes an address, which rules out most of 2017-2019.
#
# See https://github.com/planningalerts-scrapers/issues/issues/79

require "bundler/setup"
Bundler.require

require "scraperwiki"
require "mechanize"
require "date"

class Scraper
  INDEX_URL = "https://www.charterstowers.qld.gov.au/Services/Planning-and-development/" \
              "Planning-services/All-development-applications"

  # The site sits behind Akamai, which returns 403 unless the request carries
  # ordinary browser headers including all three Sec-Fetch-* headers.
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  REQUEST_HEADERS = {
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language" => "en-AU,en;q=0.9",
    "Sec-Fetch-Dest" => "document",
    "Sec-Fetch-Mode" => "navigate",
    "Sec-Fetch-Site" => "none",
  }.freeze

  # Council references like MCU2026-0001, MCU2025.0004, MC20/77, RL 19-143
  REF_RE = %r{([A-Z]{2,5})\s?(\d{2,4})[-/.](\d{1,5})\b}
  # Dashes (hyphen or en dash) used as separators between fields. A space is
  # required before the dash but not after, as the council sometimes writes
  # "REF - Description -Address"; requiring the leading space keeps street
  # ranges like "1-21 Towers Street" intact.
  DASH_RE = /\s+[-\u2013]\s*/
  STATUS_RE = /\s*[-\u2013(]\s*(?:Withdrawn|Lapsed|Approved|Refused|Refusal)\)?\s*\z/i

  STREET_TYPES = %w[
    St Street Rd Road Ln Lane Hwy Highway Ct Crt Court Tce Terrace
    Ave Avenue Dr Drive Cl Close Way Esplanade Parade
  ].freeze
  STREET_RE = /\b(?:#{STREET_TYPES.join('|')})\b/i

  # Document titles and process words that are neither description nor address
  NOISE_WORDS = [
    "Decision Notice", "Application Documentation", "Confirmation Notice",
    "Infrastructure Charges", "Exemption", "Temporary Use Agreement",
    "Approval", "Notice",
  ].freeze
  NOISE_RE = Regexp.new(
    "\\b(?:#{NOISE_WORDS.map { |w| Regexp.escape(w) }.join('|')})\\b|\\.pdf",
    Regexp::IGNORECASE
  )

  # Fallback descriptions from the application type encoded in the reference
  TYPE_BY_PREFIX = {
    "MCU" => "Material change of use", "MC" => "Material change of use",
    "RAL" => "Reconfiguring a lot", "RL" => "Reconfiguring a lot",
    "OPW" => "Operational works", "OW" => "Operational works",
    "BWAP" => "Building works", "PBW" => "Building works", "BAPC" => "Building works",
  }.freeze

  def self.run
    new.run
  end

  def initialize
    @agent = Mechanize.new
    @agent.user_agent = USER_AGENT
    @agent.request_headers = REQUEST_HEADERS.dup
    @seen = {}
    @saved = 0
  end

  def run
    puts "Running ruby #{RUBY_VERSION}"
    pages = year_pages
    # Accordion-per-application pages first as they carry the richest data,
    # then the decision notice lists, skipping references already saved.
    pages.each { |url, page| scrape_application_accordions(url, page) }
    pages.each { |url, page| scrape_notice_lists(url, page) } # rubocop:disable Style/CombinableLoops
    puts "Finished - added #{@saved} records"
  end

  private

  def year_pages
    index = @agent.get(INDEX_URL)
    hrefs = index.search("a[href*='All-development-applications/']").map { |a| a["href"] }.uniq
    raise "No year pages found at #{INDEX_URL}" if hrefs.empty?

    hrefs.map do |href|
      url = URI.join(INDEX_URL, href).to_s
      sleep 1
      [url, @agent.get(url)]
    end
  end

  def scrape_application_accordions(url, page)
    before = @saved
    page.search("article").each do |article|
      heading = clean_text(article.at("h2.item-text")&.text)
      next if heading.empty? || heading.match?(/\A\d{4}\s/)

      match = REF_RE.match(heading)
      next if match.nil? || @seen[canonical_ref(match)]

      save_accordion(article, heading, match, url)
    end
    report(url, @saved - before, "accordions")
  end

  def save_accordion(article, heading, match, url)
    address, heading_desc = split_heading(heading, match)
    return if address.empty?

    para = first_paragraph(article)
    description = para ? description_from(para) : heading_desc
    description = fallback_description(match) if description.to_s.empty?
    save(canonical_ref(match), address, description, url)
  end

  def scrape_notice_lists(url, page)
    before = @saved
    page.search("article").each do |article|
      heading = clean_text(article.at("h2.item-text")&.text)
      next unless heading.match?(/\A\d{4}\s/)

      article.search(".accordion-item-body a").each do |link|
        save_notice_link(link, url)
      end
    end
    report(url, @saved - before, "notice lists")
  end

  def save_notice_link(link, url)
    link.search("span.file-info").each(&:remove)
    text = clean_text(link.text)
    match = REF_RE.match(text)
    return if match.nil? || @seen[canonical_ref(match)]

    record = parse_notice_text(text, match)
    return if record.nil?

    save(canonical_ref(match), record[:address], record[:description], url)
  end

  # Heading is "REF - ADDRESS", occasionally with a description between the
  # reference and the address. Returns [address, description or nil].
  def split_heading(heading, match)
    remainder = heading[match.end(0)..].sub(/\A\s*[-\u2013]?\s*/, "").sub(STATUS_RE, "")
    segments = remainder.split(DASH_RE).reject(&:empty?)
    idx = segments.index { |s| addressy?(s) } || 0
    [segments[idx..].join(", "), idx.positive? ? segments[0...idx].join(" - ") : nil]
  end

  # Body paragraph is "REF - DESCRIPTION - ADDRESS" (occasionally with the
  # address first); the description itself often contains dashes, so strip the
  # reference then drop leading and trailing segments that look like an
  # address. Returns "" when nothing but an address remains, so the caller
  # falls back to the heading or the application type.
  def description_from(para)
    text = para.sub(STATUS_RE, "").sub(/\A\s*[-\u2013]?\s*/, "")
    text = strip_leading_refs(text)
    segments = text.split(DASH_RE).reject(&:empty?)
    segments.pop while segments.size > 1 && full_address?(segments.last)
    # Drop a dangling street number left behind when a range like
    # "123 - 129 Mosman Street" is written with a spaced dash
    segments.pop while segments.size > 1 && segments.last.match?(/\A[\d\s&,-]+[A-Za-z]?\z/)
    segments.shift while segments.size > 1 && full_address?(segments.first)
    return "" if segments.size == 1 && full_address?(segments.first)

    segments.join(" - ")
  end

  # Paragraphs open with the council reference, sometimes twice in different
  # formats, joined with a companion reference ("RAL2023/0006 & OPW2023/0001")
  # or interleaved with a status marker ("REF - LAPSED - REF - ...")
  def strip_leading_refs(text)
    prefix = /\A(?:[-\u2013&\s]+|lapsed|withdrawn)*\z/i
    while (match = REF_RE.match(text)) && text[0...match.begin(0)].match?(prefix)
      text = text[match.end(0)..].sub(/\A\s*[-\u2013&]?\s*/, "")
    end
    text
  end

  # Notice list link text is "REF DOC-TYPE - ADDRESS" in varying layouts.
  # Returns nil when no address can be found (most of 2017-2019).
  def parse_notice_text(text, match)
    rest = "#{text[0...match.begin(0)]} #{text[match.end(0)..]}".sub(STATUS_RE, "")
    parts = rest.split(/#{DASH_RE}|\s*;\s*|,\s+/)
                .map { |p| p.sub(/\A[-\u2013]+\s*/, "").strip }
                .reject(&:empty?)
    idx = parts.index { |p| loose_addressy?(p) }
    return nil unless idx

    address_parts = parts[idx..].take_while { |p| !p.match?(NOISE_RE) }
    return nil if address_parts.empty?

    # Everything after a part carrying the state or postcode is document
    # noise, sometimes glued straight onto the postcode without a separator
    last = address_parts.index { |p| p.match?(/\bQLD\b|\b48\d{2}\b/i) }
    address_parts = address_parts[..last].map { |p| p.sub(/(\b48\d{2})[[:alpha:]].*\z/, '\1') } if last

    description = parts[0...idx].grep_v(NOISE_RE).join(" - ")
    description = fallback_description(match) if description.empty?
    { address: address_parts.join(", "), description: description }
  end

  def first_paragraph(article)
    article.search(".accordion-item-body p").map { |p| clean_text(p.text) }.find { |t| !t.empty? }
  end

  def addressy?(segment)
    segment.match?(STREET_RE) || segment.match?(/\bQLD\b/i) || segment.match?(/\b48\d{2}\b/)
  end

  # Stricter test for stripping addresses out of descriptions, so wording
  # like "Roadworks" or "internal road" is not mistaken for an address
  def full_address?(segment)
    segment.match?(/\bQLD\b/i) || segment.match?(/\b48\d{2}\b/) ||
      (segment.match?(/\A(?:Lot\s?\d|\d)/i) && segment.match?(STREET_RE))
  end

  def loose_addressy?(part)
    addressy?(part) || part.match?(/\A(?:Lot\s?\d|\d[\w-]*\s)/i)
  end

  def canonical_ref(match)
    "#{match[1]}#{match[2]}/#{match[3]}"
  end

  def fallback_description(match)
    TYPE_BY_PREFIX[match[1]] || "Development application"
  end

  def clean_text(text)
    text.to_s.gsub(/[[:space:]]+/, " ").strip
  end

  def report(url, count, source)
    puts "#{url.split('/').last}: #{count} applications from #{source}" if count.positive?
  end

  def ensure_qld(address)
    address.match?(/\bQLD\b/i) ? address : "#{address}, QLD"
  end

  def save(ref, address, description, url)
    @seen[ref] = true
    ScraperWiki.save_sqlite(
      ["council_reference"],
      "council_reference" => ref,
      "address" => ensure_qld(address),
      "description" => description,
      "info_url" => url,
      "date_scraped" => Date.today.to_s
    )
    @saved += 1
  end
end

Scraper.run if __FILE__ == $PROGRAM_NAME
