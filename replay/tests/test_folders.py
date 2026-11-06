import sys

import pytest

from oprivview_replay import folders


@pytest.fixture
def home(tmp_path, monkeypatch):
  for var in ("APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
    monkeypatch.delenv(var, raising=False)
  monkeypatch.setattr(folders.Path, "home", classmethod(lambda cls: tmp_path))
  return tmp_path


def test_each_folder_of_the_old_name_takes_the_new_one_with_what_it_holds(home):
  for base in folders.bases():
    (base / "OPRivViewReplay").mkdir(parents=True)
    (base / "OPRivViewReplay/settings.json").write_text("{}")
  assert folders.move_old() == []
  for base in folders.bases():
    assert not (base / "OPRivViewReplay").exists()
    assert (base / "GeoRivViewReplay/settings.json").read_text() == "{}"


def test_a_folder_of_the_new_name_already_there_is_kept_and_the_old_left_alone(home):
  base = folders.bases()[0]
  (base / "OPRivViewReplay").mkdir(parents=True)
  (base / "GeoRivViewReplay").mkdir()
  (base / "GeoRivViewReplay/settings.json").write_text('{"new": 1}')
  assert folders.move_old() == []
  assert (base / "OPRivViewReplay").is_dir()
  assert (base / "GeoRivViewReplay/settings.json").read_text() == '{"new": 1}'


def test_nothing_of_the_old_name_is_nothing_to_do(home):
  assert folders.move_old() == []
  assert not any(b.exists() for b in folders.bases())


def test_the_places_are_the_systems_own(home):
  names = [str(b.relative_to(home)).replace("\\", "/") for b in folders.bases()]
  if sys.platform == "win32":
    assert names == ["AppData/Roaming", "AppData/Local"]
  elif sys.platform.startswith("linux"):
    assert names == [".config", ".cache", ".local/state"]
  else:
    assert names == ["Library/Application Support", "Library/Caches", "Library/Logs"]
