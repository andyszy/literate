#!/usr/bin/env python3
"""Unit tests for the daemon's Chrome data layer: profile enumeration, the
multi-profile omnibox history merge, and the per-profile favicon cache.

    python3 tools/test-chrome.py

No Hyprland, no Chrome, no model call -- every source is a temporary
directory built here. The daemon has no .py suffix, so it is loaded through
SourceFileLoader rather than imported.
"""

import importlib.machinery
import importlib.util
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def load_daemon():
    path = REPO / "bin" / "literate-workspace-namer"
    loader = importlib.machinery.SourceFileLoader("literate_namer", str(path))
    spec = importlib.util.spec_from_loader("literate_namer", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


namer = load_daemon()


def make_history(path, rows):
    """A minimal stand-in for Chrome's History database. `rows` are
    (url, title, visit_count, last_visit_webkit, hidden)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)  # rewriting a profile mid-test is a fresh DB
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, "
                "title LONGVARCHAR, visit_count INTEGER DEFAULT 0, "
                "typed_count INTEGER DEFAULT 0, last_visit_time INTEGER, "
                "hidden INTEGER DEFAULT 0)")
    con.executemany("INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) "
                    "VALUES (?, ?, ?, ?, ?)", rows)
    con.commit()
    con.close()


PNG = b"\x89PNG\r\n\x1a\n"


def make_favicons(path, rows):
    """A minimal stand-in for Chrome's Favicons database. `rows` are
    (page_url, width, image_data)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE icon_mapping (id INTEGER PRIMARY KEY, "
                "page_url LONGVARCHAR NOT NULL, icon_id INTEGER, "
                "page_url_type INTEGER DEFAULT 0)")
    con.execute("CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, "
                "icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0, "
                "image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0, "
                "last_requested INTEGER DEFAULT 0)")
    for icon_id, (page_url, width, data) in enumerate(rows, start=1):
        con.execute("INSERT INTO icon_mapping (page_url, icon_id) VALUES (?, ?)",
                    (page_url, icon_id))
        con.execute("INSERT INTO favicon_bitmaps (icon_id, image_data, width) "
                    "VALUES (?, ?, ?)", (icon_id, data, width))
    con.commit()
    con.close()


def webkit(unix_seconds):
    return int((unix_seconds + namer.WEBKIT_EPOCH_DELTA) * 1_000_000)


class ChromeDirTest(unittest.TestCase):
    """Everything here repoints the daemon's CHROME_DIR at a temp tree."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.chrome = Path(self.tmp.name) / "google-chrome"
        self.chrome.mkdir(parents=True)
        self._saved = (namer.CHROME_DIR, namer.CHROME_LOCAL_STATE)
        namer.CHROME_DIR = self.chrome
        namer.CHROME_LOCAL_STATE = self.chrome / "Local State"
        self.addCleanup(self.restore)

    def restore(self):
        namer.CHROME_DIR, namer.CHROME_LOCAL_STATE = self._saved
        self.tmp.cleanup()

    def write_local_state(self, info_cache):
        (self.chrome / "Local State").write_text(
            json.dumps({"profile": {"info_cache": info_cache}}))

    def rows(self, count, *, visits=10, hidden=0, when=None, prefix="https://example.com/"):
        when = time.time() if when is None else when
        return [(f"{prefix}{i}", f"page {i}", visits, webkit(when - i), hidden)
                for i in range(count)]


class TestProfileEnumeration(ChromeDirTest):

    def test_lists_every_profile_with_its_human_name(self):
        self.write_local_state({
            "Default": {"name": "Andy", "user_name": "andy@example.com"},
            "Profile 1": {"name": "tradewinds.school"},
        })
        make_history(self.chrome / "Default" / "History", [])
        make_history(self.chrome / "Profile 1" / "History", [])
        self.assertEqual(namer.chrome_profile_dirs(),
                         [("Default", "Andy"), ("Profile 1", "tradewinds.school")])

    def test_falls_back_to_globbing_when_local_state_is_unreadable(self):
        # No Local State at all, then one that is not JSON: both have to reach
        # the same place, because the profiles are still sitting right there.
        make_history(self.chrome / "Default" / "History", [])
        make_history(self.chrome / "Profile 3" / "History", [])
        self.assertEqual(namer.chrome_profile_dirs(),
                         [("Default", "Default"), ("Profile 3", "Profile 3")])
        (self.chrome / "Local State").write_text("{not json at all")
        self.assertEqual(namer.chrome_profile_dirs(),
                         [("Default", "Default"), ("Profile 3", "Profile 3")])

    def test_profile_without_a_history_database_is_skipped(self):
        # Listed in info_cache but never opened: there is nothing to read, and
        # trying anyway would log a failure on every pass forever.
        self.write_local_state({"Default": {"name": "Andy"},
                                "Profile 1": {"name": "never opened"}})
        make_history(self.chrome / "Default" / "History", [])
        (self.chrome / "Profile 1").mkdir()
        self.assertEqual(namer.chrome_profile_dirs(), [("Default", "Andy")])

    def test_chrome_profiles_config_restricts_the_set(self):
        self.write_local_state({"Default": {"name": "Andy"},
                                "Profile 1": {"name": "work"}})
        make_history(self.chrome / "Default" / "History", [])
        make_history(self.chrome / "Profile 1" / "History", [])
        self.assertEqual(namer.chrome_profile_dirs(["Profile 1"]), [("Profile 1", "work")])
        self.assertEqual(namer.chrome_profile_dirs([]),
                         [("Default", "Andy"), ("Profile 1", "work")])


class TestHistoryMerge(ChromeDirTest):

    def setUp(self):
        super().setUp()
        self.write_local_state({"Default": {"name": "Andy"},
                                "Profile 1": {"name": "tradewinds.school"}})

    def test_rows_are_tagged_with_their_profile(self):
        make_history(self.chrome / "Default" / "History",
                     [("https://a.example/1", "a", 5, webkit(time.time()), 0)])
        make_history(self.chrome / "Profile 1" / "History",
                     [("https://b.example/1", "b", 5, webkit(time.time()), 0)])
        by_url = {r["url"]: r for r in namer.build_history()}
        self.assertEqual(by_url["https://a.example/1"]["profile"], "Default")
        self.assertEqual(by_url["https://a.example/1"]["profileName"], "Andy")
        self.assertEqual(by_url["https://b.example/1"]["profileName"], "tradewinds.school")

    def test_the_same_url_in_two_profiles_stays_two_rows(self):
        now = time.time()
        make_history(self.chrome / "Default" / "History",
                     [("https://mail.google.com/", "Inbox", 400, webkit(now), 0)])
        make_history(self.chrome / "Profile 1" / "History",
                     [("https://mail.google.com/", "Inbox", 3, webkit(now), 0)])
        rows = [r for r in namer.build_history() if r["url"] == "https://mail.google.com/"]
        self.assertEqual(len(rows), 2)
        # ...and neither one absorbed the other's visit count.
        self.assertEqual(sorted(r["visits"] for r in rows), [3, 400])

    def test_the_floor_keeps_a_small_profile_alive_under_the_cap(self):
        # The shape this whole change exists for: one profile with far more
        # history than the cap, one with a handful of rows.
        make_history(self.chrome / "Default" / "History", self.rows(300, visits=100))
        make_history(self.chrome / "Profile 1" / "History",
                     self.rows(5, visits=1, prefix="https://work.example/"))
        kept = namer.build_history(limit=100, floor=10)
        self.assertEqual(len(kept), 100)
        small = [r for r in kept if r["profile"] == "Profile 1"]
        self.assertEqual(len(small), 5, "every row the small profile has must survive")
        # Without a floor the big profile sweeps the cap: that is the bug.
        starved = namer.build_history(limit=100, floor=0)
        self.assertEqual([r for r in starved if r["profile"] == "Profile 1"], [])

    def test_a_profile_hands_back_floor_it_cannot_use(self):
        make_history(self.chrome / "Default" / "History", self.rows(300, visits=100))
        make_history(self.chrome / "Profile 1" / "History",
                     self.rows(2, visits=1, prefix="https://work.example/"))
        kept = namer.build_history(limit=50, floor=10)
        self.assertEqual(len(kept), 50)
        self.assertEqual(len([r for r in kept if r["profile"] == "Default"]), 48)

    def test_floors_never_add_up_to_more_than_the_cap(self):
        for i in range(8):
            directory = "Default" if i == 0 else f"Profile {i}"
            make_history(self.chrome / directory / "History",
                         self.rows(50, prefix=f"https://p{i}.example/"))
        self.write_local_state({("Default" if i == 0 else f"Profile {i}"): {"name": f"p{i}"}
                                for i in range(8)})
        kept = namer.build_history(limit=40, floor=30)
        self.assertEqual(len(kept), 40)
        # Equal shares rather than the first few profiles eating everything.
        for i in range(8):
            directory = "Default" if i == 0 else f"Profile {i}"
            self.assertEqual(len([r for r in kept if r["profile"] == directory]), 5)

    def test_hidden_rows_only_top_a_profile_up_to_its_floor(self):
        # A freshly signed-in profile whose history arrived over sync: every
        # row hidden, no local visits. It still has to be findable.
        make_history(self.chrome / "Default" / "History", self.rows(100, visits=50))
        make_history(self.chrome / "Profile 1" / "History",
                     self.rows(6, visits=0, hidden=1, prefix="https://work.example/"))
        kept = namer.build_history(limit=50, floor=10)
        self.assertEqual(len([r for r in kept if r["profile"] == "Profile 1"]), 6)
        # The big profile has plenty of its own, so its hidden rows stay out.
        make_history(self.chrome / "Profile 1" / "History",
                     self.rows(4, visits=0, hidden=1, prefix="https://work.example/")
                     + self.rows(40, visits=9, prefix="https://work.example/v"))
        kept = namer.build_history(limit=50, floor=10)
        work = [r for r in kept if r["profile"] == "Profile 1"]
        self.assertTrue(all(r["url"].startswith("https://work.example/v") for r in work),
                        "hidden rows must not pad a profile that has visible ones")

    def test_one_profile_is_exactly_the_old_behaviour(self):
        self.write_local_state({"Default": {"name": "Andy"}})
        make_history(self.chrome / "Default" / "History", self.rows(500, visits=7))
        kept = namer.build_history(limit=100, floor=10)
        self.assertEqual(len(kept), 100)
        self.assertTrue(all(r["profile"] == "Default" for r in kept))

    def test_an_unreadable_database_costs_the_other_profiles_nothing(self):
        make_history(self.chrome / "Default" / "History", self.rows(5))
        (self.chrome / "Profile 1").mkdir()
        (self.chrome / "Profile 1" / "History").write_text("this is not a database")
        kept = namer.build_history(limit=50, floor=10)
        self.assertEqual(len(kept), 5)

    def test_no_chrome_at_all_yields_no_rows(self):
        self.assertEqual(namer.build_history(), [])


class TestFavicons(ChromeDirTest):

    def setUp(self):
        super().setUp()
        self.write_local_state({"Default": {"name": "Andy"},
                                "Profile 1": {"name": "work"}})
        make_history(self.chrome / "Default" / "History", [])
        make_history(self.chrome / "Profile 1" / "History", [])
        self.icons = Path(self.tmp.name) / "favicons"

    @staticmethod
    def row(domain, profile):
        return {"domain": domain, "profile": profile, "url": f"https://{domain}/"}

    def attach(self, entries):
        namer.attach_favicons(entries, directory=self.icons)
        return entries

    def read(self, entry):
        return Path(entry["favicon"]).read_bytes()

    def test_a_row_takes_its_own_profile_s_icon_first(self):
        # The same site, signed in twice, with a different icon each side.
        make_favicons(self.chrome / "Default" / "Favicons",
                      [("https://mail.google.com/", 32, PNG + b"personal")])
        make_favicons(self.chrome / "Profile 1" / "Favicons",
                      [("https://mail.google.com/", 32, PNG + b"work")])
        rows = self.attach([self.row("mail.google.com", "Default"),
                            self.row("mail.google.com", "Profile 1")])
        self.assertEqual(self.read(rows[0]), PNG + b"personal")
        self.assertEqual(self.read(rows[1]), PNG + b"work")

    def test_another_profile_s_icon_beats_a_blank_square(self):
        make_favicons(self.chrome / "Default" / "Favicons",
                      [("https://github.com/anything", 32, PNG + b"octocat")])
        make_favicons(self.chrome / "Profile 1" / "Favicons", [])
        rows = self.attach([self.row("github.com", "Profile 1")])
        self.assertEqual(self.read(rows[0]), PNG + b"octocat")

    def test_one_file_per_image_however_many_rows_share_it(self):
        make_favicons(self.chrome / "Default" / "Favicons",
                      [("https://github.com/a", 32, PNG + b"octocat")])
        rows = self.attach([self.row("github.com", "Default") for _ in range(5)])
        self.assertEqual(len({r["favicon"] for r in rows}), 1)
        self.assertEqual(len(list(self.icons.glob("*.png"))), 1)

    def test_the_widest_bitmap_under_the_ceiling_wins(self):
        make_favicons(self.chrome / "Default" / "Favicons", [
            ("https://example.com/", 16, PNG + b"small"),
            ("https://example.com/", 32, PNG + b"right"),
            ("https://example.com/", 512, PNG + b"huge"),
        ])
        rows = self.attach([self.row("example.com", "Default")])
        self.assertEqual(self.read(rows[0]), PNG + b"right")

    def test_an_icon_no_row_points_at_any_more_is_deleted(self):
        make_favicons(self.chrome / "Default" / "Favicons",
                      [("https://old.example/", 32, PNG + b"old"),
                       ("https://new.example/", 32, PNG + b"new")])
        self.attach([self.row("old.example", "Default")])
        self.attach([self.row("new.example", "Default")])
        self.assertEqual([p.read_bytes() for p in self.icons.glob("*.png")], [PNG + b"new"])

    def test_a_blob_that_is_not_a_png_is_skipped(self):
        make_favicons(self.chrome / "Default" / "Favicons",
                      [("https://example.com/", 32, b"GIF89a nope")])
        rows = self.attach([self.row("example.com", "Default")])
        self.assertNotIn("favicon", rows[0])

    def test_a_missing_favicons_database_costs_nothing(self):
        rows = self.attach([self.row("example.com", "Default")])
        self.assertNotIn("favicon", rows[0])


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0], *sys.argv[1:]])
