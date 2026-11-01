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

from . import jobs, params, ssh_source
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


def make_app(host: str = "comma", cache: Path = DEFAULT_CACHE, renderer: Path = DEFAULT_APP, output_dir: Path = Path.home() / "Movies") -> FastAPI:
  app = FastAPI(title="OPRivView replay")
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
    try:
      listing = ssh_source.list_routes(host)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
      return {"online": False, "error": f"cannot reach {host}: {e}", "routes": []}
    newest_first = sorted(listing.items(), reverse=True)
    return {"online": True, "routes": [{"route": r, "segments": s, "first": s[0], "last": s[-1]} for r, s in newest_first]}

  def _resolve(r: Range):
    try:
      return jobs.resolve(host, cache, r.route, r.start_segment, r.end_segment, r.start_time, r.end_time)
    except RangeError as e:
      raise HTTPException(422, str(e))
    except (subprocess.CalledProcessError, OSError) as e:
      raise HTTPException(502, f"could not fetch from {host}: {e}")

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
    output = Path(req.output) if req.output else output_dir / f"{req.route}.mp4"
    job_id = uuid.uuid4().hex[:8]
    state[job_id] = {"id": job_id, "state": "running", "message": "starting", "progress": None, "output": str(output), "error": None,
                     "range": resolved.describe()}

    def progress(text: str):
      with lock:
        state[job_id]["message"] = text
        if text.startswith("frame "):
          parts = text.split()
          state[job_id]["progress"] = int(parts[1]) / int(parts[3])

    def work():
      try:
        output.parent.mkdir(parents=True, exist_ok=True)
        jobs.render_resolved(resolved, host, cache, settings, output, renderer, progress)
        with lock:
          state[job_id].update(state="done", message="finished", progress=1.0)
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
  p.add_argument("--exit-with-parent", action="store_true", help="stop when the program that started this server ends")
  a = p.parse_args()
  if a.exit_with_parent:
    parent = os.getppid()

    def watch():
      while os.getppid() == parent:
        time.sleep(1)
      os._exit(0)

    threading.Thread(target=watch, daemon=True).start()
  uvicorn.run(make_app(a.host, a.cache, a.app), host="127.0.0.1", port=a.port, log_level="warning")


if __name__ == "__main__":
  main()
