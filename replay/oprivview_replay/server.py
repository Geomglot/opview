"""Local server the desktop app talks to. Listens on 127.0.0.1 only.

  python -m oprivview_replay.server --port 8765
"""
import argparse
import os
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from . import admin, jobs, params, places, render
from .settings import Settings
from .sources import ConnectSource, DeviceSource, SourceError, parse_drive_ref
from .cli import DEFAULT_APP, DEFAULT_CACHE
from .logs import index_segment
from .timeline import RangeError


class Cancelled(Exception):
  """the user stopped this job; raised out of its progress report, which every long step makes"""


class Range(BaseModel):
  route: str
  start_segment: int | None = None
  end_segment: int | None = None
  start_time: str | None = None
  end_time: str | None = None


class RenderRequest(Range):
  options: dict = {}
  output: str | None = None
  preview: bool = False  # prepare the drive for the window to play, without encoding an MP4


class SettingsChange(BaseModel):
  host: str | None = None
  dongle: str | None = None
  output_dir: str | None = None
  test_versions: bool | None = None


class Address(BaseModel):
  address: str


class Token(BaseModel):
  token: str


class Drive(BaseModel):
  text: str


class Seek(BaseModel):
  job_file: str
  frame: int


def default_output(folder: Path, range_: dict, route: str) -> Path:
  """a name that says which part of the drive this is, and never replaces an earlier clip"""
  first, last = range_["start_segment"], range_["end_segment"]
  stem = f"{route}--seg{first}" if first == last else f"{route}--seg{first}-{last}"
  path = folder / f"{stem}.mp4"
  n = 2
  while path.exists():
    path = folder / f"{stem} ({n}).mp4"
    n += 1
  return path


def _chosen_output(text: str) -> Path:
  path = Path(text).expanduser()
  return path if path.suffix.lower() == ".mp4" else path.with_name(path.name + ".mp4")


DEFAULT_OUTPUT_DIR = Path.home() / ("Videos" if sys.platform == "win32" else "Movies")


def make_app(host: str | None = None, cache: Path = DEFAULT_CACHE, renderer: Path = DEFAULT_APP, output_dir: Path = DEFAULT_OUTPUT_DIR,
             connect: ConnectSource | None = ConnectSource(), settings: Settings | None = None) -> FastAPI:
  """[settings] is the user's saved choices; [host] is one given on the command line, which wins over them"""
  app = FastAPI(title="OPRivView replay")
  settings = settings or Settings(Path(tempfile.mkdtemp()) / "settings.json")
  sources = jobs.Sources(DeviceSource(host or settings["host"]), connect)
  if connect is not None and settings["dongle"]:
    connect.use_device(settings["dongle"])
  public_sources: dict[str, ConnectSource] = {}
  state: dict[str, dict] = {}
  renderers: dict[str, object] = {}  # job -> its running renderer process
  lock = threading.Lock()

  @app.get("/health")
  def health():
    return {"ok": True}

  @app.get("/params")
  def get_params():
    return params.describe()

  @app.get("/routes")
  def routes():
    """one row per drive, newest first, from the comma and comma Connect together"""
    rows: dict[str, dict] = {}
    problems = []
    device_up = False
    try:
      for route, segs in sources.device.routes().items():
        rows[route] = {"route": route, "segments": segs, "on_device": True, "on_connect": False}
      device_up = True
    except SourceError as e:
      problems.append(str(e))
    metric = sources.device.is_metric() if device_up else None
    if sources.connect is not None and sources.connect.available():
      try:
        for route, info in sources.connect.listing().items():
          row = rows.setdefault(route, {"route": route, "segments": info["segments"], "on_device": False})
          _connect_details(row, info)
      except SourceError as e:
        problems.append(str(e))
    problems += _add_public_rows(rows)
    for row in rows.values():
      segs = row["segments"]
      row["first"], row["last"] = segs[0], segs[-1]
      row["local_start"] = _local_start(row)
      # what a replay can show: everything if the comma has it, otherwise only what Connect keeps
      row["detail"] = "full" if row["on_device"] else row.get("detail", "small")
    # drives added by hand first, where they can be found, and then the user's own, newest first
    ordered = sorted(sorted(rows.values(), key=lambda r: r["route"], reverse=True), key=lambda r: not r.get("public"))
    return {"online": device_up, "metric": metric, "error": "; ".join(problems) or None, "routes": ordered}

  def _connect_details(row: dict, info: dict) -> None:
    row.update(on_connect=True, start_ms=info["start_ms"], end_ms=info["end_ms"], km=info["km"], lat=info["lat"], lon=info["lon"],
               place=places.journey(info["start"], info["end"]))

  def _public_source(dongle: str) -> ConnectSource:
    return public_sources.setdefault(dongle, ConnectSource(dongle=dongle, public=True))

  def _add_public_rows(rows: dict[str, dict]) -> list[str]:
    """someone else's drives the user has added; anything that has stopped being public is reported, not fatal"""
    problems = []
    sources.added.clear()
    for entry in settings["added"]:
      try:
        dongle, route = parse_drive_ref(entry)
        source = _public_source(dongle)
        found = {route: source.route_info(route)} if route else source.listing()
        for name, info in found.items():
          if name in rows:
            continue  # the user's own comma or account has it, with more files
          sources.added[name] = source
          rows[name] = {"route": name, "segments": info["segments"], "on_device": False, "public": True, "entry": entry, "dongle": dongle,
                        "detail": source.best_detail(name, info["segments"])}
          _connect_details(rows[name], info)
      except SourceError as e:
        problems.append(f"{entry}: {e}")
    return problems

  def _local_start(row: dict) -> str | None:
    if row.get("start_ms") is None:
      return None
    from datetime import datetime
    from .timeline import zone_for
    when = datetime.fromtimestamp(row["start_ms"] / 1000)
    place = _position(row)
    if place is None:  # where the drive was is not known
      if sys.platform == "win32":  # Windows names zones in full ("SA Pacific Standard Time") and has no abbreviations
        local = when.astimezone()
        offset = local.strftime("%z")
        return local.strftime("%Y-%m-%d %H:%M") + f" UTC{offset[:3]}:{offset[3:]} (this computer's time)"
      return when.astimezone().strftime("%Y-%m-%d %H:%M %Z") + " (Mac time)"
    return when.astimezone(zone_for(*place)).strftime("%Y-%m-%d %H:%M %Z")

  def _position(row: dict) -> tuple[float, float] | None:
    """where the drive was, for its time zone: from Connect, which has none for some drives, or from a log already here"""
    if row.get("lat") or row.get("lon"):
      return row["lat"], row["lon"]
    for log in sorted((cache / row["route"]).glob("*/qlog.zst"))[:3]:
      i = index_segment(log)
      if i.lat is not None:
        return i.lat, i.lon
    return None

  def _resolve(r: Range):
    try:
      return jobs.resolve(sources, cache, r.route, r.start_segment, r.end_segment, r.start_time, r.end_time)
    except RangeError as e:
      raise HTTPException(422, str(e))

  @app.post("/resolve")
  def resolve(r: Range):
    return _resolve(r).describe()

  @app.post("/jobs")
  def start_job(req: RenderRequest):
    try:
      options = params.settings_from_dict(req.options)
    except ValueError as e:
      raise HTTPException(422, str(e))
    resolved = _resolve(req)
    folder = Path(settings["output_dir"]).expanduser() if settings["output_dir"] else output_dir
    output = _chosen_output(req.output) if req.output else default_output(folder, resolved.describe(), req.route)
    job_id = uuid.uuid4().hex[:8]
    state[job_id] = {"id": job_id, "state": "running", "message": "starting", "progress": None, "output": str(output), "error": None, "preview": req.preview, "job_file": None,
                     "range": resolved.describe()}

    def progress(text: str):
      with lock:
        if state[job_id]["state"] == "cancelled":
          raise Cancelled()
        state[job_id]["message"] = text
        if text.startswith("frame "):
          parts = text.split()
          state[job_id]["progress"] = int(parts[1]) / int(parts[3])

    def work():
      try:
        if not req.preview:
          output.parent.mkdir(parents=True, exist_ok=True)
        job_file = jobs.render_resolved(resolved, sources, cache, options, output, renderer, progress, preview=req.preview,
                                        started=lambda p: renderers.__setitem__(job_id, p))
        with lock:
          if state[job_id]["state"] == "running":
            state[job_id].update(state="done", message="ready" if req.preview else "finished", progress=1.0,
                                 job_file=str(job_file) if job_file else None)
      except Cancelled:
        pass
      except Exception as e:  # report anything to the interface rather than lose it in the thread
        detail = getattr(e, "stderr", None) or str(e)
        with lock:
          if state[job_id]["state"] == "running":
            state[job_id].update(state="failed", error=str(detail)[-2000:])
      finally:
        renderers.pop(job_id, None)

    threading.Thread(target=work, daemon=True).start()
    return state[job_id]

  @app.post("/jobs/{job_id}/cancel")
  def cancel(job_id: str):
    if job_id not in state:
      raise HTTPException(404, "no such job")
    with lock:
      if state[job_id]["state"] == "running":
        state[job_id].update(state="cancelled", message="stopped")
      running = renderers.get(job_id)
    if running is not None:
      running.kill()
    with lock:
      return dict(state[job_id])

  @app.post("/preview/seek")
  def preview_seek(s: Seek):
    job_file = Path(s.job_file)
    if job_file.name != "preview-job.json" or cache.resolve() not in job_file.resolve().parents:
      raise HTTPException(422, "that is not a prepared preview")
    return render.seek(job_file, s.frame)

  @app.get("/settings")
  def get_settings():
    devices, signed_in = [], connect is not None and admin.token_status(connect)["state"] == "ok"
    if signed_in:
      try:
        devices = [{"dongle": d["dongle_id"], "name": d.get("alias") or d["dongle_id"]} for d in connect.devices()]
      except SourceError:
        pass
    return {"host": sources.device.host, "dongle": connect.dongle() if devices else settings["dongle"], "devices": devices,
            "output_dir": settings["output_dir"] or str(output_dir), "token": admin.token_status(connect) if connect else None,
            "key": admin.key_info(), "cache_bytes": admin.cache_size(cache), "cache_path": str(cache),
            "test_versions": settings["test_versions"]}

  @app.put("/settings")
  def put_settings(c: SettingsChange):
    changes = c.model_dump(exclude_unset=True)
    if "host" in changes:
      changes["host"] = admin.host_for(changes["host"])
      sources.device.host = changes["host"]
    if "dongle" in changes and connect is not None:
      connect.use_device(changes["dongle"])
    settings.update(**changes)
    return get_settings()

  @app.post("/settings/check-host")
  def check_host(a: Address):
    return admin.check_host(admin.host_for(a.address))

  @app.post("/settings/find-comma")
  def find_comma():
    return admin.find_commas()

  @app.post("/settings/ssh-key")
  def ssh_key():
    return admin.create_key()

  @app.post("/settings/token")
  def set_token(t: Token):
    if connect is None:
      raise HTTPException(422, "comma Connect is turned off")
    try:
      admin.save_token(connect, t.token)
    except SourceError as e:
      raise HTTPException(422, str(e))
    return admin.token_status(connect)

  @app.post("/settings/clear-cache")
  def clear_cache():
    with lock:
      busy = any(j["state"] == "running" for j in state.values())
    if busy:
      raise HTTPException(409, "wait for the job in progress to finish")
    admin.clear_cache(cache)
    return {"cache_bytes": admin.cache_size(cache)}

  @app.post("/drives/add")
  def add_drive(d: Drive):
    """a public drive of someone else's, from a Connect link, or every public drive of a device from its id"""
    try:
      dongle, route = parse_drive_ref(d.text)
      source = _public_source(dongle)
      found = [route] if route else list(source.listing())
      if route:
        source.route_info(route)
    except SourceError as e:
      raise HTTPException(422, str(e))
    entry = f"{dongle}|{route}" if route else dongle
    if entry not in settings["added"]:
      settings.update(added=[*settings["added"], entry])
    return {"entry": entry, "routes": found}

  @app.post("/drives/remove")
  def remove_drive(d: Drive):
    settings.update(added=[e for e in settings["added"] if e != d.text])
    return {"ok": True}

  @app.get("/jobs/{job_id}")
  def job(job_id: str):
    if job_id not in state:
      raise HTTPException(404, "no such job")
    with lock:
      return dict(state[job_id])

  return app


def _windows_parent_watch(parent: int):
  """On Windows a process keeps the parent id it was started with after the parent ends, so watching os.getppid() never
  sees a change. Hold the parent's process handle instead (opened now, so a reused id cannot fool it) and wait on it."""
  import ctypes
  from ctypes import wintypes

  kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
  kernel32.OpenProcess.restype = wintypes.HANDLE
  kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
  kernel32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
  synchronize, infinite = 0x00100000, 0xFFFFFFFF
  handle = kernel32.OpenProcess(synchronize, False, parent)

  def watch():
    if handle:  # no handle means the parent has already gone
      kernel32.WaitForSingleObject(handle, infinite)
    os._exit(0)

  return watch


def main() -> None:
  p = argparse.ArgumentParser()
  p.add_argument("--port", type=int, default=8765)
  p.add_argument("--host", help="SSH host of the comma; without this, the one chosen in the app's settings")
  p.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
  p.add_argument("--app", type=Path, default=DEFAULT_APP, help="the built renderer")
  p.add_argument("--no-connect", action="store_true", help="do not use comma Connect")
  p.add_argument("--exit-with-parent", action="store_true", help="stop when the program that started this server ends")
  # on Windows a venv's python.exe is a launcher that starts the real Python as its own child and waits for it, so the
  # parent this server sees is the launcher, which never ends first. The app says who it is instead.
  p.add_argument("--parent-pid", type=int, help="with --exit-with-parent on Windows: the app to watch, if not the direct parent")
  a = p.parse_args()
  if a.exit_with_parent:
    parent = os.getppid()
    if sys.platform == "win32":
      watch = _windows_parent_watch(a.parent_pid or parent)
    else:
      def watch():
        while os.getppid() == parent:
          time.sleep(1)
        os._exit(0)

    threading.Thread(target=watch, daemon=True).start()
  uvicorn.run(make_app(a.host, a.cache, a.app, connect=None if a.no_connect else ConnectSource(), settings=Settings()), host="127.0.0.1", port=a.port, log_level="warning")


if __name__ == "__main__":
  main()
