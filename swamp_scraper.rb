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
end

def extract_game_id(echl_game_url)
  html = URI.open(echl_game_url).read
  doc = Nokogiri::HTML(html)
  link = doc.css('a[href*="game_reports/official-game-report.php"]').find { |a| a['href'] =~ /game_id=(\d+)/ }
  link&.[]('href')&.match(/game_id=(\d+)/)&.captures&.first
end

def parse_game_sheet(game_id)
  url = "#{GAME_REPORT_BASE}#{game_id}"
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
    entry = if assists.empty?
              "#{scorer} (unassisted)"
            else
              "#{scorer} (#{assists})"
            end
    if team == "GVL"
      home_goals << entry
    elsif team == "UTA"
      away_goals << entry
    end
  end

  score = { home: home_goals.size, away: away_goals.size }
  { score:, home_goals:, away_goals: }
end

games = []
ics = URI.open(ICS_URL).read
events = ics.split("BEGIN:VEVENT")

events.each do |event|
  dtstart = event.lines.find { |l| l.start_with?("DTSTART") }
  next unless dtstart
  date = extract_date(dtstart)
  next if date > DateTime.now

  opponent = event.lines.find { |l| l.include?("SUMMARY:") }&.split(':')&.last&.strip&.gsub("vs ", "") || "Unknown"
  location = event.include?("LOCATION:Bon Secours") ? "Home" : "Away"
  slug = slugify(opponent)
  date_path = date.strftime("%Y/%m/%d")
  echl_url = "#{BASE_URL}/#{date_path}/greenville-swamp-rabbits-vs-#{slug}"

  begin
    game_id = extract_game_id(echl_url)
    next unless game_id
    puts "🧲 Found game_id #{game_id} for #{date.strftime("%b %d")} vs #{opponent}"

    data = parse_game_sheet(game_id)
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
  rescue => e
    puts "⚠️ Failed to process game on #{date}: #{e}"
  end
end

File.write("swamp_schedule.json", JSON.pretty_generate(games))
puts "✅ Saved swamp_schedule.json with #{games.size} games"
