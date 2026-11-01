"""Builds oprivview_replay/places.tsv.gz, the town list behind the names in the drive list, from GeoNames cities1000
(https://download.geonames.org/export/dump/, CC BY 4.0: places of 1000 people or more).
  python packaging/build_places.py <path to cities1000.zip>"""
import csv
import gzip
import io
import sys
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "oprivview_replay" / "places.tsv.gz"


def main(zip_path: str) -> None:
  rows = []
  with zipfile.ZipFile(zip_path) as z, z.open("cities1000.txt") as f:
    for r in csv.reader(io.TextIOWrapper(f, "utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE):
      name, lat, lon, feature = r[1], float(r[4]), float(r[5]), r[7]
      if feature != "PPLX":  # a section of a town rather than a town
        rows.append(f"{name}\t{lat:.3f}\t{lon:.3f}\n")
  with gzip.GzipFile(OUT, "wb", mtime=0) as out:
    out.write("".join(rows).encode())
  print(f"{len(rows)} places, {OUT.stat().st_size >> 10} KB")


if __name__ == "__main__":
  main(sys.argv[1])
