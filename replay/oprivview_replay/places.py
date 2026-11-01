"""The town nearest a position, from a list built into the app, so naming a drive needs no network or account.
Place data: GeoNames (geonames.org), CC BY 4.0; see packaging/build_places.py."""
import gzip
import math
from functools import lru_cache
from pathlib import Path

DATA = Path(__file__).with_name("places.tsv.gz")
MAX_KM = 40  # further than this from any town, the drive is simply somewhere without a name


@lru_cache(maxsize=1)
def _grid() -> dict[tuple[int, int], list[tuple[str, float, float]]]:
  """places by whole degree of latitude and longitude, so a search looks at a few hundred rather than all of them"""
  grid: dict[tuple[int, int], list[tuple[str, float, float]]] = {}
  with gzip.open(DATA, "rt", encoding="utf-8") as f:
    for line in f:
      name, lat, lon = line.rstrip("\n").split("\t")
      la, lo = float(lat), float(lon)
      grid.setdefault((math.floor(la), math.floor(lo)), []).append((name, la, lo))
  return grid


def _km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
  x = math.radians(lon2 - lon1) * math.cos(math.radians((lat1 + lat2) / 2))
  return 6371 * math.hypot(x, math.radians(lat2 - lat1))


def nearest_town(lat: float | None, lon: float | None) -> str | None:
  if lat is None or lon is None or (not lat and not lon):
    return None
  grid = _grid()
  cell_la, cell_lo = math.floor(lat), math.floor(lon)
  best, best_km = None, float(MAX_KM)
  for la in (cell_la - 1, cell_la, cell_la + 1):
    for lo in (cell_lo - 1, cell_lo, cell_lo + 1):
      for name, p_la, p_lo in grid.get((la, (lo + 180) % 360 - 180), ()):
        km = _km(lat, lon, p_la, p_lo)
        if km < best_km:
          best, best_km = name, km
  return best


def journey(start: tuple[float | None, float | None], end: tuple[float | None, float | None]) -> str | None:
  """"Fort Collins to Timnath", or one town when the drive stayed in it or only one end is known"""
  a, b = nearest_town(*start), nearest_town(*end)
  if a and b and a != b:
    return f"{a} to {b}"
  return a or b
