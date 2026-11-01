"""Local server the desktop app talks to. Listens on 127.0.0.1 only.

  python -m oprivview_replay.server --port 8765
"""
import argparse
import os
import subprocess
import threading
import time
import uuid
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from . import jobs, params
from .sources import ConnectSource, DeviceSource, SourceError
from .cli import DEFAULT_APP, DEFAULT_CACHE
from .timeline import RangeError


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


def make_app(host: str = "comma", cache: Path = DEFAULT_CACHE, renderer: Path = DEFAULT_APP, output_dir: Path = Path.home() / "Movies",
             connect: ConnectSource | None = ConnectSource()) -> FastAPI:
  app = FastAPI(title="OPRivView replay")
  sources = jobs.Sources(DeviceSource(host), connect)
  state: dict[str, dict] = {}
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
          row.update(on_connect=True, start_ms=info["start_ms"], end_ms=info["end_ms"], km=info["km"], lat=info["lat"], lon=info["lon"])
      except SourceError as e:
        problems.append(str(e))
    for row in rows.values():
      segs = row["segments"]
      row["first"], row["last"] = segs[0], segs[-1]
      row["local_start"] = _local_start(row)
      # what a replay can show: everything if the comma has it, otherwise only what Connect keeps
      row["detail"] = "full" if row["on_device"] else "quick"
    ordered = sorted(rows.values(), key=lambda r: r["route"], reverse=True)
    return {"online": device_up, "metric": metric, "error": "; ".join(problems) or None, "routes": ordered}

  def _local_start(row: dict) -> str | None:
    if row.get("start_ms") is None or row.get("lat") is None:
      return None
    from datetime import datetime
    from .timeline import zone_for
    return datetime.fromtimestamp(row["start_ms"] / 1000, zone_for(row["lat"], row["lon"])).strftime("%Y-%m-%d %H:%M %Z")

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
      settings = params.settings_from_dict(req.options)
    except ValueError as e:
      raise HTTPException(422, str(e))
    resolved = _resolve(req)
    output = _chosen_output(req.output) if req.output else default_output(output_dir, resolved.describe(), req.route)
    job_id = uuid.uuid4().hex[:8]
    state[job_id] = {"id": job_id, "state": "running", "message": "starting", "progress": None, "output": str(output), "error": None, "preview": req.preview, "job_file": None,
                     "range": resolved.describe()}

    def progress(text: str):
      with lock:
        state[job_id]["message"] = text
        if text.startswith("frame "):
          parts = text.split()
          state[job_id]["progress"] = int(parts[1]) / int(parts[3])

    def work():
      try:
        if not req.preview:
          output.parent.mkdir(parents=True, exist_ok=True)
        job_file = jobs.render_resolved(resolved, sources, cache, settings, output, renderer, progress, preview=req.preview)
        with lock:
          state[job_id].update(state="done", message="ready" if req.preview else "finished", progress=1.0,
                               job_file=str(job_file) if job_file else None)
      except Exception as e:  # report anything to the interface rather than lose it in the thread
        detail = getattr(e, "stderr", None) or str(e)
        with lock:
          state[job_id].update(state="failed", error=str(detail)[-2000:])

    threading.Thread(target=work, daemon=True).start()
    return state[job_id]

  @app.get("/jobs/{job_id}")
  def job(job_id: str):
    if job_id not in state:
      raise HTTPException(404, "no such job")
    with lock:
      return dict(state[job_id])

  return app


def main() -> None:
  p = argparse.ArgumentParser()
  p.add_argument("--port", type=int, default=8765)
  p.add_argument("--host", default="comma", help="SSH host of the comma")
  p.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
  p.add_argument("--app", type=Path, default=DEFAULT_APP, help="the built renderer")
  p.add_argument("--no-connect", action="store_true", help="do not use comma Connect")
  p.add_argument("--exit-with-parent", action="store_true", help="stop when the program that started this server ends")
  a = p.parse_args()
  if a.exit_with_parent:
    parent = os.getppid()

    def watch():
      while os.getppid() == parent:
        time.sleep(1)
      os._exit(0)

    threading.Thread(target=watch, daemon=True).start()
  uvicorn.run(make_app(a.host, a.cache, a.app, connect=None if a.no_connect else ConnectSource()), host="127.0.0.1", port=a.port, log_level="warning")


if __name__ == "__main__":
  main()
