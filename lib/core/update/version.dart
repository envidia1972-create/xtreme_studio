/// Comparacion de versiones tipo `major.minor.patch`.
library;

List<int> versionParts(String version) {
  var value = version.trim();
  if (value.startsWith('v') || value.startsWith('V')) {
    value = value.substring(1);
  }
  final plus = value.indexOf('+');
  if (plus >= 0) value = value.substring(0, plus);
  final dash = value.indexOf('-');
  if (dash >= 0) value = value.substring(0, dash);
  final parts = <int>[];
  for (final piece in value.split('.')) {
    final match = RegExp(r'^\d+').firstMatch(piece);
    parts.add(match == null ? 0 : int.parse(match.group(0)!));
  }
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts;
}

/// Devuelve >0 si [latest] es mas nueva que [current], 0 si son iguales y <0
/// si [latest] es anterior.
int _buildNumber(String version) {
  final plus = version.indexOf('+');
  if (plus < 0 || plus == version.length - 1) return 0;
  final match = RegExp(r'^\d+').firstMatch(version.substring(plus + 1));
  return match == null ? 0 : int.parse(match.group(0)!);
}

int compareVersions(String latest, String current) {
  final a = versionParts(latest);
  final b = versionParts(current);
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left.compareTo(right);
  }
  return _buildNumber(latest).compareTo(_buildNumber(current));
}

bool isNewerVersion(String latest, String current) =>
    compareVersions(latest, current) > 0;
