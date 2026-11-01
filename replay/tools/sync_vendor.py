#!/usr/bin/env python3
"""Copy what the replay tool shares with the comma's code into oprivview_replay/vendor.

The replay has to send the app exactly what webrtcd sends it live, so it runs the comma's own slimming code and
reads logs with the comma's own schemas rather than keeping copies by hand. Run this again whenever dys-a changes:

  python replay/tools/sync_vendor.py /path/to/openpilot--dys-a
"""
import ast
import shutil
import sys
from pathlib import Path

VENDOR = Path(__file__).resolve().parent.parent / "oprivview_replay" / "vendor"


def extract_functions(source: Path, names: list[str]) -> str:
  """opview_model lives in webrtcd.py, which cannot be imported off the device; lift out just these functions"""
  text = source.read_text()
  found = {n.name: ast.get_source_segment(text, n) for n in ast.parse(text).body if isinstance(n, ast.FunctionDef)}
  missing = [n for n in names if n not in found]
  if missing:
    sys.exit(f"{missing} not found in {source}")
  return "\n\n\n".join(found[n] for n in names)


def main() -> None:
  root = Path(sys.argv[1])
  op = root / "openpilot"
  VENDOR.mkdir(exist_ok=True)
  (VENDOR / "include").mkdir(exist_ok=True)
  shutil.copy(op / "system/webrtc/opview_slim.py", VENDOR / "opview_slim.py")
  for name in ("log.capnp", "custom.capnp", "deprecated.capnp"):
    shutil.copy(op / "cereal" / name, VENDOR / name)
  shutil.copy(op / "cereal/include/c++.capnp", VENDOR / "include/c++.capnp")
  shutil.copy(root / "opendbc_repo/opendbc/car/car.capnp", VENDOR / "car.capnp")
  model = extract_functions(op / "system/webrtc/webrtcd.py", ["_xyz", "opview_model"])
  (VENDOR / "opview_model.py").write_text(f'"""Copied from webrtcd.py by tools/sync_vendor.py. Do not edit."""\nfrom typing import Any\n\n\n{model}\n')
  (VENDOR / "__init__.py").touch()
  print(f"vendored into {VENDOR}")


if __name__ == "__main__":
  main()
