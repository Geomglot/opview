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


def test_into_a_folder_of_the_new_name_already_there_goes_what_it_lacks(home):
  base = folders.bases()[0]
  (base / "OPRivViewReplay/0000005a--f16da7af40").mkdir(parents=True)
  (base / "OPRivViewReplay/settings.json").write_text('{"old": 1}')
  (base / "GeoRivViewReplay").mkdir()
  (base / "GeoRivViewReplay/settings.json").write_text('{"new": 1}')
  assert folders.move_old() == []
  assert not (base / "OPRivViewReplay").exists()
  assert (base / "GeoRivViewReplay/0000005a--f16da7af40").is_dir()
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


def test_a_folder_that_cannot_be_moved_stays_in_use_and_is_moved_at_a_later_start(home, monkeypatch):
  base = folders.bases()[1]
  (base / "OPRivViewReplay/0000005a--f16da7af40").mkdir(parents=True)
  real = folders.Path.rename

  def held(self, target):  # as Windows refuses while a program has a file in the folder open
    raise PermissionError("in use")

  monkeypatch.setattr(folders.Path, "rename", held)
  assert len(folders.move_old()) == 1
  assert folders.folder(base) == base / "OPRivViewReplay", "the drives stored there are still found"
  # meanwhile the app wrote its log under the new name
  (base / "GeoRivViewReplay/Logs").mkdir(parents=True)
  (base / "GeoRivViewReplay/Logs/preview.log").write_text("new")
  (base / "OPRivViewReplay/Logs").mkdir()
  (base / "OPRivViewReplay/Logs/preview.log").write_text("old")

  monkeypatch.setattr(folders.Path, "rename", real)
  assert folders.move_old() == []
  assert not (base / "OPRivViewReplay").exists()
  assert folders.folder(base) == base / "GeoRivViewReplay"
  assert (base / "GeoRivViewReplay/0000005a--f16da7af40").is_dir()
  assert (base / "GeoRivViewReplay/Logs/preview.log").read_text() == "new"


def test_the_server_uses_the_folders_as_they_are_after_the_move(home):
  from oprivview_replay import cli, settings
  for base in folders.bases():
    (base / "OPRivViewReplay").mkdir(parents=True)
  assert cli.default_cache().is_relative_to(folders.bases()[1] / "OPRivViewReplay")
  folders.move_old()
  assert cli.default_cache().is_relative_to(folders.bases()[1] / "GeoRivViewReplay")
  assert settings.default_file() == folders.bases()[0] / "GeoRivViewReplay/settings.json"
