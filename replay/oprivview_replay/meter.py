"""How far a fetch has got and how long the rest should take, from the bytes that have arrived."""
import time
from collections import deque
from typing import Callable

WINDOW_S = 30  # the speed is what arrived over the last half minute, so it follows a connection that speeds up or slows
SETTLE_S = 3  # too little has arrived before this to say how long the rest will take


def time_left(seconds: float | None) -> str:
  if seconds is None:
    return "working out the time left"
  if seconds < 5:
    return "almost done"
  if seconds < 60:
    return f"about {round(seconds / 5) * 5} s left"
  minutes = round(seconds / 60)
  if minutes < 60:
    return f"about {minutes} min left"
  return f"about {minutes // 60} h {minutes % 60} min left"


def megabytes(n: float) -> str:
  return f"{n / 1e6:,.0f}"


class Meter:
  """Fed (bytes here, bytes in all) as a fetch goes; gives what the window shows. What was already here when the fetch
  began counts as done but not towards the speed, so a fetch that carries on from a cancelled one is not over-quick."""

  def __init__(self, what: str, clock: Callable[[], float] = time.monotonic):
    self.what = what
    self.clock = clock
    self.samples: deque[tuple[float, int]] = deque()

  def update(self, done: int, total: int) -> dict:
    now = self.clock()
    self.samples.append((now, done))
    while len(self.samples) > 2 and now - self.samples[1][0] >= WINDOW_S:
      self.samples.popleft()
    (t0, d0), span = self.samples[0], now - self.samples[0][0]
    rate = (done - d0) / span if span >= SETTLE_S else None
    left = None
    if total <= 0:  # nothing known yet of what is coming
      left = None
    elif done >= total:
      left = 0.0
    elif rate:
      left = (total - done) / rate
    return {"what": self.what, "done": done, "total": total, "seconds_left": None if left is None else round(left)}

  @staticmethod
  def describe(status: dict) -> str:
    """e.g. "fetching the full files from connect: 120 of 800 MB, about 4 min left" """
    return (f"fetching {status['what']}: {megabytes(status['done'])} of {megabytes(status['total'])} MB, "
            f"{time_left(status['seconds_left'])}")
