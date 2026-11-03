# PyInstaller spec for the replay server, one-directory mode.
# Run from the replay folder:  pyinstaller packaging/server.spec --distpath dist --workpath build -y
import sys

from PyInstaller.utils.hooks import collect_all, collect_data_files

# capnp schemas and the town list are read as files at run time
datas = [("../oprivview_replay/vendor", "oprivview_replay/vendor"), ("../oprivview_replay/places.tsv.gz", "oprivview_replay")]
binaries = []
hidden = ["uvicorn.logging", "uvicorn.loops.auto", "uvicorn.protocols.http.auto", "uvicorn.protocols.websockets.auto",
          "uvicorn.lifespan.on", "anyio._backends._asyncio"]
# Windows has no time zone database of its own, so zoneinfo reads the one in the tzdata package; a Mac uses its own
for pkg in ("capnp", "timezonefinder", "zstandard", *(["tzdata"] if sys.platform == "win32" else [])):
  d, b, h = collect_all(pkg)
  datas += d
  binaries += b
  hidden += h

a = Analysis(["sidecar_main.py"], pathex=[SPECPATH + "/.."], binaries=binaries, datas=datas, hiddenimports=hidden,
             excludes=["tkinter", "pytest"], noarchive=False)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="oprivview-replay-server", console=True, upx=False)
coll = COLLECT(exe, a.binaries, a.datas, name="oprivview-replay-server", upx=False)
