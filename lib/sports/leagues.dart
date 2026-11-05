import 'espn.dart';

/// Competitions offered in "Pick sports". Paths are ESPN's.
const leagues = <League>[
  League('Soccer', 'soccer/eng.1', 'Premier League'),
  League('Soccer', 'soccer/eng.2', 'EFL Championship'),
  League('Soccer', 'soccer/eng.fa', 'FA Cup'),
  League('Soccer', 'soccer/eng.league_cup', 'Carabao Cup'),
  League('Soccer', 'soccer/sco.1', 'Scottish Premiership'),
  League('Soccer', 'soccer/uefa.champions', 'Champions League'),
  League('Soccer', 'soccer/uefa.europa', 'Europa League'),
  League('Soccer', 'soccer/uefa.europa.conf', 'Conference League'),
  League('Soccer', 'soccer/esp.1', 'LaLiga'),
  League('Soccer', 'soccer/ger.1', 'Bundesliga'),
  League('Soccer', 'soccer/ita.1', 'Serie A'),
  League('Soccer', 'soccer/fra.1', 'Ligue 1'),
  League('Soccer', 'soccer/usa.1', 'MLS'),
  League('American Football', 'football/nfl', 'NFL'),
  League('American Football', 'football/college-football', 'College Football'),
  League('Basketball', 'basketball/nba', 'NBA'),
  League('Basketball', 'basketball/wnba', 'WNBA'),
  League('Basketball', 'basketball/mens-college-basketball', 'College Basketball'),
  League('Baseball', 'baseball/mlb', 'MLB'),
  League('Ice Hockey', 'hockey/nhl', 'NHL'),
  League('Motorsport', 'racing/f1', 'Formula 1'),
  League('Motorsport', 'racing/irl', 'IndyCar'),
  League('Combat Sports', 'mma/ufc', 'UFC'),
];

League? leagueByPath(String path) {
  for (final l in leagues) {
    if (l.path == path) return l;
  }
  return null;
}

List<String> get sportGroups => leagues.map((l) => l.sport).toSet().toList();
