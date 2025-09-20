import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Call this once at app startup
void initializeTimeZones() {
  tzdata.initializeTimeZones();
}

tz.Location getLocalTimeZone() {
  final String localName = DateTime.now().timeZoneName;
  try {
    return tz.getLocation(localName);
  } catch (_) {
    return tz.getLocation('UTC');
  }
}

tz.TZDateTime getNowInLocalTime() {
  final location = getLocalTimeZone();
  return tz.TZDateTime.now(location);
}

