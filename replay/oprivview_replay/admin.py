"""The work behind the app's settings page: finding the comma, SSH keys, the comma Connect token and the cache."""
import base64
import concurrent.futures
import json
import os
import re
import shutil
import socket
import subprocess
import time
from pathlib import Path

from . import ssh_source
from .sources import ConnectSource, SourceError

SSH_DIR = Path.home() / ".ssh"
KEY_NAMES = ("id_ed25519", "id_ecdsa", "id_rsa")
_DONGLE_ID = re.compile(r"^[0-9a-f]{16}$")
_ADDRESS = re.compile(r"\binet (\d+\.\d+\.\d+)\.\d+\b")


def host_for(address: str) -> str:
  """a bare address needs the comma's user name; a name from ~/.ssh/config, or user@address, is used as it is"""
  address = address.strip()
  return f"comma@{address}" if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", address) else address


def check_host(host: str) -> dict:
  """is this a comma we can log in to? {ok, dongle, error}"""
  try:
    text = ssh_source.run(host, "cat /data/params/d/DongleId").strip()
  except subprocess.TimeoutExpired:
    return {"ok": False, "dongle": None, "error": f"{host} did not answer"}
  except subprocess.CalledProcessError as e:
    return {"ok": False, "dongle": None, "error": (e.stderr or str(e)).strip()[-300:]}
  if not _DONGLE_ID.match(text):
    return {"ok": False, "dongle": None, "error": f"{host} answered, but it does not look like a comma"}
  return {"ok": True, "dongle": text, "error": None}


def local_prefixes(ifconfig: str | None = None) -> list[str]:
  """the first three numbers of each network this Mac is on"""
  if ifconfig is None:
    ifconfig = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True).stdout
  found: list[str] = []
  for prefix in _ADDRESS.findall(ifconfig):
    if not prefix.startswith(("127.", "169.254.")) and prefix not in found:
      found.append(prefix)
  return found


def _ssh_open(address: str, timeout: float = 0.6) -> bool:
  """only whether the port answers: a busy comma can be slow to say more, and [check_host] does the deciding anyway"""
  try:
    with socket.create_connection((address, 22), timeout=timeout):
      return True
  except OSError:
    return False


def find_commas(prefixes: list[str] | None = None) -> list[dict]:
  """every address next to this Mac with SSH open, and whether each is a comma we can log in to; commas first.
  An open port is not enough: printers and other computers run SSH too, so each one is asked for its comma id."""
  addresses = [f"{p}.{n}" for p in (local_prefixes() if prefixes is None else prefixes) for n in range(1, 255)]
  with concurrent.futures.ThreadPoolExecutor(64) as pool:
    open_ones = [a for a, up in zip(addresses, pool.map(_ssh_open, addresses)) if up]
    checks = list(pool.map(lambda a: check_host(host_for(a)), open_ones))
  found = [{"address": a, "comma": c["ok"], "dongle": c["dongle"]} for a, c in zip(open_ones, checks)]
  return sorted(found, key=lambda f: not f["comma"])


def _public_keys() -> list[Path]:
  return [SSH_DIR / f"{name}.pub" for name in KEY_NAMES if (SSH_DIR / f"{name}.pub").exists()]


def key_info() -> dict:
  """the public half only; the private key is never read here"""
  keys = _public_keys()
  return {"path": str(keys[0]), "public_key": keys[0].read_text().strip()} if keys else {"path": None, "public_key": None}


def create_key() -> dict:
  """a new key for this Mac, unless it has one already"""
  if not _public_keys():
    SSH_DIR.mkdir(mode=0o700, exist_ok=True)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "oprivview-replay", "-f", str(SSH_DIR / "id_ed25519")], check=True)
  return key_info()


def _expiry(token: str) -> int | None:
  """when a token runs out, read from its middle section, which is not secret and needs no key to read"""
  try:
    body = token.split(".")[1]
    return int(json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))["exp"])
  except (IndexError, KeyError, ValueError):
    return None


def token_status(connect: ConnectSource) -> dict:
  """{state: missing, expired or ok, expires}. The token itself never leaves this function."""
  try:
    token = connect.jwt_file.read_text().strip()
  except OSError:
    return {"state": "missing", "expires": None}
  expires = _expiry(token)
  return {"state": "expired" if expires and expires < time.time() else "ok", "expires": expires}


def save_token(connect: ConnectSource, token: str) -> None:
  """keeps [token] only if comma Connect accepts it, readable by this user alone"""
  token = token.strip()
  connect.check_token(token)
  connect.jwt_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
  tmp = connect.jwt_file.with_name(connect.jwt_file.name + ".tmp")
  fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
  with os.fdopen(fd, "w") as f:
    f.write(token + "\n")
  os.replace(tmp, connect.jwt_file)
  connect.forget()


def cache_size(cache: Path) -> int:
  return sum(p.stat().st_size for p in cache.rglob("*") if p.is_file()) if cache.exists() else 0


def clear_cache(cache: Path) -> None:
  """everything in it can be fetched again; a drive that has since left the comma and Connect cannot, which the app says"""
  if cache.exists():
    for child in cache.iterdir():
      shutil.rmtree(child) if child.is_dir() else child.unlink()
