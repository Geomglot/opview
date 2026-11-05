"""Entry point for the packaged server."""
import os
import sys

# On Linux, PyInstaller's starter points LD_LIBRARY_PATH at the libraries it unpacked, and every program the server runs
# would inherit it: the computer's own ffmpeg, ssh and the renderer would then load the server's copies of shared
# libraries instead of their own, and can fail. The server itself has loaded its libraries by now, so put back what the
# computer had (PyInstaller keeps it in LD_LIBRARY_PATH_ORIG) for those programs.
if sys.platform.startswith("linux") and getattr(sys, "frozen", False):
  original = os.environ.pop("LD_LIBRARY_PATH_ORIG", None)
  if original is None:
    os.environ.pop("LD_LIBRARY_PATH", None)
  else:
    os.environ["LD_LIBRARY_PATH"] = original

from oprivview_replay.server import main  # noqa: E402

if __name__ == "__main__":
  if sys.argv[1:] == ["--print-encoding"]:  # for the build's checks: how this server would encode on this computer
    from oprivview_replay import render
    print(render.encoding(render._tool("ffmpeg")))
    sys.exit(0)
  main()
