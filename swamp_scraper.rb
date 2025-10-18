require 'open-uri'
require 'nokogiri'
require 'json'

BASE_URL = "https://echl.com/games"
GAME_REPORT_BASE = "https://lscluster.hockeytech.com/game_reports/official-game-report.php?client_code=echl&game_id="
ICS_URL = "https://swamprabbits.com/schedule-all.ics"

def slugify(name)
  name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')
end

def extract_date(line)
  raw = line.split(':').last.strip
  DateTime.strptime(raw, '%Y%m%dT%H%M%S')
rescue
  puts "❌ Failed to parse date from line: #{line}"
  nil
end

def extract_game_id(echl_game_url)
  puts "🔗 Fetching ECHL game page: #{echl_game_url}"
  html = URI.open(echl_game_url).read
  doc = Nokogiri::HTML(html)

  link = doc.css('a[href*="game_reports/official-game-report.php"]').find { |a| a['href'] =~ /game_id=(\d+)/ }
  if link
    match = link['href'].match(/game_id=(\d+)/)
    if match
      puts "🧲 Found game_id: #{match[1]}"
      return match[1]
    end
  end

  puts "❌ No game_id found in page"
  nil
rescue => e
  puts "⚠️ Failed to fetch or parse ECHL page: #{e}"
  nil
end

def parse_game_sheet(game_id)
  url = "#{GAME_REPORT_BASE}#{game_id}"
  puts "📄 Fetching game sheet: #{url}"
  html = URI.open(url).read
  doc = Nokogiri::HTML(html)

  rows = doc.css('table').select { |t| t.text.include?("Scoring Summary") }.flat_map { |t| t.css('tr') }
  home_goals, away_goals = [], []

  rows.each do |row|
    cells = row.css('td').map(&:text).map(&:strip)
    next unless cells.size >= 5
    team = cells[1]
    scorer = cells[3].split('(').first.strip
    assists = cells[4].strip
    entry = assists.empty? ? "#{scorer} (unassisted)" : "#{scorer} (#{assists})"

    if team == "GVL"
      home_goals << entry
    elsif team != "GVL"
      away_goals << entry
    end
  end

  score = { home: home_goals.size, away: away_goals.size }
  puts "📊 Parsed score: GVL #{score[:home]} – #{score[:away]}"
  { score:, home_goals:, away_goals: }
rescue => e
  puts "⚠️ Failed to parse game sheet for game_id #{game_id}: #{e}"
  { score: { home: 0, away: 0 }, home_goals: [], away_goals: [] }
end

games = []
ics = URI.open(ICS_URL).read
events = ics.split("BEGIN:VEVENT")
puts "📅 Found #{events.size} events in ICS"

events.each do |event|
  dtstart = event.lines.find { |l| l.start_with?("DTSTART") }
  next unless dtstart
  date = extract_date(dtstart)
  next unless date
  if date > DateTime.now
    puts "⏳ Skipping future game on #{date}"
    next
  end

  opponent = event.lines.find { |l| l.include?("SUMMARY:") }&.split(':')&.last&.strip&.gsub("vs ", "") || "Unknown"
  location = event.include?("LOCATION:Bon Secours") ? "Home" : "Away"
  slug = slugify(opponent)
  date_path = date.strftime("%Y/%m/%d")
  echl_url = "#{BASE_URL}/#{date_path}/greenville-swamp-rabbits-vs-#{slug}"

  game_id = extract_game_id(echl_url)
  next unless game_id

  data = parse_game_sheet(game_id)
  if data[:home_goals].any? || data[:away_goals].any?
    games << {
      game_id: game_id.to_i,
      date: date.strftime("%a, %b %d"),
      status: "Final",
      home_team: "Greenville",
      away_team: opponent,
      home_score: data[:score][:home],
      away_score: data[:score][:away],
      game_report_url: "#{GAME_REPORT_BASE}#{game_id}",
      home_goals: data[:home_goals],
      away_goals: data[:away_goals]
    }
  else
    puts "⚠️ No goals found for game_id #{game_id} — skipping"
  end
end

File.write("swamp_schedule.json", JSON.pretty_generate(games))
puts "✅ Saved swamp_schedule.json with #{games.size} games"
