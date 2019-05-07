require 'scraperwiki'
require 'mechanize'
require 'date'

url = 'http://www.charterstowers.qld.gov.au/recently-submitted-applications'
agent = Mechanize.new

page = agent.get url

table = page.search(:table).last

table.search(:tr).each_with_index do |row,number|
  next if number == 0 # Skip header

  columns = row.search(:td)


  date_received = Date.strptime(columns[1].inner_text.strip, '%d/%m/%Y') rescue nil
  
  record = {
    council_reference: columns[0].inner_text,
    date_received:     date_received,
    description:       columns[3].inner_text,
    address:           "#{columns[4].inner_text}, QLD",
    info_url:          url,
    comment_url:       'mailto:mail@charterstowers.qld.gov.au', 
    date_scraped:      Date.today
  }
  # puts record.to_yaml
  ScraperWiki.save_sqlite([:council_reference], record)
end
