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

from . import admin, jobs, params, places, render, ssh_source
from .settings import Settings
from .uploads import UploadRequests
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
  via_server: bool | None = None
  keep_on_connect: bool | None = None


class Address(BaseModel):
  address: str


class Token(BaseModel):
  token: str


class Drive(BaseModel):
  text: str


class Answer(BaseModel):
  copy_now: bool


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


def _linux_videos() -> Path:
  """the Videos folder the desktop names (xdg-user-dir; another language may call it something else), else ~/Videos"""
  try:
    named = subprocess.run(["xdg-user-dir", "VIDEOS"], capture_output=True, text=True, timeout=5).stdout.strip()
  except (OSError, subprocess.TimeoutExpired):
    named = ""
  # with no Videos folder set, xdg-user-dir answers the home folder itself, which is no place for clips
  return Path(named) if named and Path(named) != Path.home() else Path.home() / "Videos"


if sys.platform == "win32":
  DEFAULT_OUTPUT_DIR = Path.home() / "Videos"
elif sys.platform.startswith("linux"):
  DEFAULT_OUTPUT_DIR = _linux_videos()
else:
  DEFAULT_OUTPUT_DIR = Path.home() / "Movies"


def make_app(host: str | None = None, cache: Path = DEFAULT_CACHE, renderer: Path = DEFAULT_APP, output_dir: Path = DEFAULT_OUTPUT_DIR,
             connect: ConnectSource | None = ConnectSource(), settings: Settings | None = None) -> FastAPI:
  """[settings] is the user's saved choices; [host] is one given on the command line, which wins over them"""
  app = FastAPI(title="OPRivView replay")
  settings = settings or Settings(Path(tempfile.mkdtemp()) / "settings.json")
  if connect is not None and settings["dongle"]:
    connect.use_device(settings["dongle"])

  def through_server() -> DeviceSource | None:
    """the comma through comma's SSH server, if this user may use it: the setting is on, and Connect says the device is
    theirs (a shared one may list as prime yet refuse their key) and has comma prime, which the server needs"""
    if not settings["via_server"] or connect is None or not connect.available() or getattr(connect, "public", False):
      return None
    try:
      dongle = connect.dongle()
      device = next((d for d in connect.devices() if d.get("dongle_id") == dongle), None)
    except SourceError:
      return None
    if device is None or not device.get("prime") or not device.get("is_owner"):
      return None
    return DeviceSource(ssh_source.ThroughServer(dongle, cache / "through-server"))

  upload_requests = UploadRequests(cache / "upload-requests.json")

  def request_upload(route: str, files: list[tuple[int, str]]) -> str | None:
    """ask the comma to put those of [files] that Connect lacks on Connect, unless "Keep a copy on comma Connect" is off,
    or they were asked for in the last 7 days. Says what was done, for the job's note."""
    if not settings["keep_on_connect"] or connect is None or not connect.available() or getattr(connect, "public", False):
      return None
    connect.forget_route(route)  # what Connect has now, not when the drive was listed
    wanted = [(s, n) for s, n in files if connect.missing(route, [s], (n,))]
    if not wanted:
      return None
    if upload_requests.asked_recently(route, wanted):
      return "The comma was already asked to upload the full files to comma Connect."
    result = connect.request_upload(route, wanted)
    asked = [f for f in wanted if f not in result["missing"]]
    if asked:
      upload_requests.add(route, asked, result["offline"])
    gone = f" The comma no longer has {len(result['missing'])} of them." if result["missing"] else ""
    if not asked:
      return "The comma no longer has the full files of this range, so they cannot be put on comma Connect."
    if result["offline"]:
      return f"Asked the comma to upload the full files to comma Connect when it is next online.{gone}"
    return f"Asked the comma to upload the full files to comma Connect, on an unmetered connection.{gone}"

  sources = jobs.Sources(DeviceSource(host or settings["host"]), connect, through_server=through_server,
                         request_upload=request_upload)
  public_sources: dict[str, ConnectSource] = {}
  state: dict[str, dict] = {}
  renderers: dict[str, object] = {}  # job -> its running renderer process
  answers: dict[str, tuple[threading.Event, dict]] = {}  # job -> what its open question is waiting on, and the answer
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
    away = None
    try:
      for route, segs in sources.device.routes().items():
        rows[route] = {"route": route, "segments": segs, "on_device": True, "on_connect": False}
      device_up = True
    except SourceError as e:
      away = str(e)
    metric = sources.device.is_metric() if device_up else None
    connect_up = False
    if sources.connect is not None and sources.connect.available():
      try:
        for route, info in sources.connect.listing().items():
          row = rows.setdefault(route, {"route": route, "segments": info["segments"], "on_device": False})
          _connect_details(row, info)
        connect_up = True
      except SourceError as e:
        problems.append(str(e))
    if away is not None:
      # with Connect answering, a comma away from this network is a normal case, not a fault: say what happens instead,
      # and keep ssh's own words for the log
      print(f"the comma on this network did not answer: {away}", file=sys.stderr)
      if connect_up:
        problems.insert(0, "The comma is not on this network, so the drives are listed from comma Connect."
                        + (" With comma prime, full detail comes from the comma through comma's server." if settings["via_server"] else ""))
      else:
        problems.insert(0, away)
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
      return when.astimezone().strftime("%Y-%m-%d %H:%M %Z") + (" (Mac time)" if sys.platform == "darwin" else " (this computer's time)")
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
    state[job_id] = {"id": job_id, "state": "running", "message": "starting", "progress": None, "output": str(output), "error": None, "preview": req.preview, "job_file": None, "snapshot": None, "stopping": False,
                     "question": None, "question_kind": None, "note": None, "range": resolved.describe(),
                     # while files are coming: {what, done, total (bytes), seconds_left (None until it can be told)}
                     "fetch": None}

    def note(text: str) -> None:
      with lock:
        state[job_id]["note"] = text

    def ask(question: str, kind: str = "metered") -> bool:
      """wait for the window to answer [question] (POST /jobs/{id}/answer); Cancel ends the wait, and the job. [kind]
      says which it is, for the window's buttons: "metered" (copy now, or not now) or "many" (fetch, or cancel)"""
      answered = threading.Event()
      with lock:
        answers[job_id] = (answered, {})
        state[job_id].update(question=question, question_kind=kind, message="waiting for an answer")
      try:
        while not answered.wait(0.5):
          with lock:
            if state[job_id]["state"] == "cancelled":
              raise Cancelled()
        return answers[job_id][1]["copy"]
      finally:
        with lock:
          answers.pop(job_id, None)
          state[job_id].update(question=None, question_kind=None)

    def progress(text: str):
      with lock:
        if state[job_id]["state"] == "cancelled":
          raise Cancelled()
        if not state[job_id]["stopping"]:
          state[job_id]["message"] = text
        if text.startswith("frame "):
          parts = text.split()
          state[job_id]["progress"] = int(parts[1]) / int(parts[3])
          # the picture the renderer has reached, once it has written one, for the window to show while it waits
          if not req.preview and render.snapshot_file(resolved.route_dir).exists():
            state[job_id]["snapshot"] = str(render.snapshot_file(resolved.route_dir))

    def fetching(status: dict | None) -> None:
      """the bar shows how much of a fetch has come; it is the render's own progress again after"""
      with lock:
        state[job_id]["fetch"] = status
        state[job_id]["progress"] = status["done"] / status["total"] if status and status["total"] else None

    def work():
      try:
        if not req.preview:
          output.parent.mkdir(parents=True, exist_ok=True)
        made = jobs.render_resolved(resolved, sources, cache, options, output, renderer, progress, preview=req.preview,
                                    started=lambda p: renderers.__setitem__(job_id, p), ask=ask, note=note,
                                    fetching=fetching)
        with lock:
          if state[job_id]["state"] != "running":
            pass
          elif req.preview:
            state[job_id].update(state="done", message="ready", progress=1.0, job_file=str(made) if made else None)
          elif state[job_id]["stopping"] and made is None:
            state[job_id].update(state="cancelled", message="stopped before the first frame", snapshot=None)
          elif state[job_id]["stopping"]:
            state[job_id].update(state="done", message="Stopped early. The clip ends where the render stopped.", progress=1.0,
                                 snapshot=None, output=str(made))
          else:
            state[job_id].update(state="done", message="finished", progress=1.0, snapshot=None)
      except Cancelled:
        pass
      except Exception as e:  # report anything to the interface rather than lose it in the thread
        detail = getattr(e, "stderr", None) or str(e)
        with lock:
          if state[job_id]["state"] == "running":
            state[job_id].update(state="failed", error=str(detail)[-2000:], snapshot=None)
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
        state[job_id].update(state="cancelled", message="stopped", snapshot=None, fetch=None)
      running = renderers.get(job_id)
    if running is not None:
      running.kill()
    with lock:
      return dict(state[job_id])

  @app.post("/jobs/{job_id}/answer")
  def answer(job_id: str, a: Answer):
    """the user's answer to the job's question: whether to copy over the comma's metered connection now"""
    with lock:
      waiting = answers.get(job_id)
      if waiting is None:
        raise HTTPException(409, "this job is not waiting for an answer")
      waiting[1]["copy"] = a.copy_now
      waiting[0].set()
      return dict(state[job_id])

  @app.post("/jobs/{job_id}/finish")
  def finish(job_id: str):
    """stop a render early and keep what it has made so far, as a clip marked partial. Before the renderer has started
    there is nothing to keep, so it is the same as cancel."""
    if job_id not in state:
      raise HTTPException(404, "no such job")
    with lock:
      running = renderers.get(job_id)
      if running is not None and state[job_id]["state"] == "running" and not state[job_id]["preview"]:
        state[job_id].update(stopping=True, message="saving what is done so far")
        render.request_stop(running)
        return dict(state[job_id])
    return cancel(job_id)

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
            "test_versions": settings["test_versions"], "via_server": settings["via_server"],
            "keep_on_connect": settings["keep_on_connect"]}

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

  @app.get("/uploads/{route}")
  def upload_status(route: str):
    """How an upload to Connect the app asked for is going, for the drive pane: how many of the files Connect has now,
    and what the comma says about its queue (it may not answer while offline). Once Connect has them all the request is
    forgotten and "done" is true once, so the window can list the drive again at its new detail."""
    asked = upload_requests.get(route)
    if asked is None or connect is None:
      return {"requested": False}
    files = [tuple(f) for f in asked["files"]]
    connect.forget_route(route)
    try:
      still = [(s, n) for s, n in files if connect.missing(route, [s], (n,))]
    except SourceError:
      still = files
    out = {"requested": True, "at": asked["at"], "files": len(files), "uploaded": len(files) - len(still), "done": not still}
    if not still:
      upload_requests.drop(route)
      return out
    queue = connect.upload_queue()
    mine = [q for q in queue or [] if q["route"] == route]
    current = next((q for q in mine if q["current"]), None)
    out.update(answered=queue is not None, queued=len(mine),
               current={"segment": current["segment"], "file": current["file"], "progress": current["progress"]} if current else None)
    if mine and current is None:  # queued but not going: say whether the comma is holding back for a metered connection
      network = connect.network()
      out["metered"] = None if network is None else network["metered"]
    return out

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
