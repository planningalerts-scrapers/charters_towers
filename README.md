# Charters Towers Regional Council scraper

This is a scraper that runs on [Morph](https://morph.io). To get started [see the documentation](https://morph.io/documentation).

It scrapes development applications for [Charters Towers Regional Council](https://www.charterstowers.qld.gov.au/) from the [All Development Applications](https://www.charterstowers.qld.gov.au/Services/Planning-and-development/Planning-services/All-development-applications) pages, one page per year, and feeds [PlanningAlerts](https://www.planningalerts.org.au/authorities/charters_towers).

Issues with this authority are tracked in the shared issue tracker: [planningalerts-scrapers/issues#79](https://github.com/planningalerts-scrapers/issues/issues/79).

## How the site is structured

- Pages from 2022 onwards list one accordion per application. The accordion heading is `REF - ADDRESS` and the first body paragraph is `REF - DESCRIPTION - ADDRESS`.
- Pages for 2017-2021 (and a leftover accordion on the 2022 page) are flat lists of decision notice PDFs. A record is extracted when the link text contains an address; most 2017-2019 links carry only a reference so they are skipped.
- The application received date is not published anywhere on these pages, so `date_received` is not set.
- The site sits behind Akamai, which rejects requests without ordinary browser headers (including the `Sec-Fetch-*` set).

## Running

```
bundle install
bundle exec ruby scraper.rb
```

Expected output is a per-year-page count of records found followed by:

```
Finished - added N records
```

with N around 200, and a `data.sqlite` file in the working directory.
