from datetime import datetime

from oprivview_replay.sun import daylight


def ms(text):
  return int(datetime.fromisoformat(text).timestamp() * 1000)


def test_toronto_in_november():
  # sunrise 06:56 and sunset 17:05 local (EST, UTC-5) on 5 November 2026
  assert not daylight(43.65, -79.38, ms("2026-11-05T06:45:00-05:00"))
  assert daylight(43.65, -79.38, ms("2026-11-05T07:05:00-05:00"))
  assert daylight(43.65, -79.38, ms("2026-11-05T16:55:00-05:00"))
  assert not daylight(43.65, -79.38, ms("2026-11-05T17:15:00-05:00"))


def test_the_far_north_and_the_southern_summer():
  assert daylight(69.65, 18.96, ms("2026-06-21T01:00:00+02:00")), "midnight sun in Tromso"
  assert not daylight(69.65, 18.96, ms("2026-12-21T12:00:00+01:00")), "polar night"
  assert daylight(-33.87, 151.21, ms("2026-12-21T19:30:00+11:00")), "a December evening in Sydney is still light"
