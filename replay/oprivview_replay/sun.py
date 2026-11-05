"""Whether the sun was up, for the drive list's Day and Night filter: the sun's height above the horizon at a place and
time, by the usual low-precision formulas (good to a few minutes of sunrise and sunset, which is all a filter needs)."""

import math

# the sun's middle is this far below the horizon at sunrise and sunset, once the air's bending of light is allowed for
SUNRISE_DEGREES = -0.833


def elevation(lat: float, lon: float, ms: int) -> float:
  """degrees above the horizon, at [ms] milliseconds since 1970 (UTC)"""
  d = ms / 86_400_000 + 2440587.5 - 2451545.0  # days since noon on 1 January 2000
  g = math.radians((357.529 + 0.98560028 * d) % 360)  # the sun's mean anomaly
  q = (280.459 + 0.98564736 * d) % 360  # its mean longitude
  ecliptic = math.radians(q + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g))
  tilt = math.radians(23.439 - 0.00000036 * d)
  right_ascension = math.atan2(math.cos(tilt) * math.sin(ecliptic), math.cos(ecliptic))
  declination = math.asin(math.sin(tilt) * math.sin(ecliptic))
  sidereal = math.radians(((18.697374558 + 24.06570982441908 * d) % 24) * 15 + lon)
  hour_angle = sidereal - right_ascension
  la = math.radians(lat)
  return math.degrees(math.asin(math.sin(la) * math.sin(declination) + math.cos(la) * math.cos(declination) * math.cos(hour_angle)))


def daylight(lat: float, lon: float, ms: int) -> bool:
  """between sunrise and sunset"""
  return elevation(lat, lon, ms) > SUNRISE_DEGREES
