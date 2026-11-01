"""Copied from webrtcd.py by tools/sync_vendor.py. Do not edit."""
from typing import Any


def _xyz(v) -> dict[str, list[float]]:
  # metres, rounded to the millimetre: far shorter JSON than full float precision
  return {"x": [round(a, 3) for a in v.x], "y": [round(a, 3) for a in v.y], "z": [round(a, 3) for a in v.z]}


def opview_model(m) -> dict[str, Any]:
  # only the modelV2 fields opview draws (path, lane lines, road edges, acceleration, confidence);
  # the full message is ~32 kB of JSON and most of webrtcd's work at 20 Hz
  return {
    "position": _xyz(m.position),
    "laneLines": [_xyz(line) for line in m.laneLines],
    "laneLineProbs": [round(p, 3) for p in m.laneLineProbs],
    "roadEdges": [_xyz(edge) for edge in m.roadEdges],
    "roadEdgeStds": [round(sd, 3) for sd in m.roadEdgeStds],
    "acceleration": {"x": [round(a, 3) for a in m.acceleration.x]},
    # for the confidence ball: how likely the model thinks a takeover is
    "meta": {"disengagePredictions": {
      "brakeDisengageProbs": [round(p, 3) for p in m.meta.disengagePredictions.brakeDisengageProbs],
      "steerOverrideProbs": [round(p, 3) for p in m.meta.disengagePredictions.steerOverrideProbs],
    }},
  }
