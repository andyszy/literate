#!/usr/bin/env python3
"""Unit tests for the daemon's Chrome data layer: profile enumeration, the
multi-profile omnibox history merge, the per-profile favicon cache, and the
merge of the literate-tabs extension's per-instance tab files.

    python3 tools/test-chrome.py

No Hyprland, no Chrome, no model call -- every source is a temporary
directory built here. The daemon has no .py suffix, so it is loaded through
SourceFileLoader rather than imported.
"""

import importlib.machinery
import importlib.util
import json
import os
import sqlite3
import struct
import subprocess
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
# The daemon logs to the live ~/.local/state/literate/daemon.log; a test run has
# no business appending to the log someone tails to watch the real thing.
_LOG = tempfile.NamedTemporaryFile(prefix="literate-test-", suffix=".log", delete=False)
namer.LOG_PATH = Path(_LOG.name)


def make_history(path, rows):
    """A minimal stand-in for Chrome's History database. `rows` are
    (url, title, visit_count, last_visit_webkit, hidden) with an optional
    sixth element, typed_count -- left off, a row was never typed, which is
    true of all but 379 of the 13,077 URLs on the machine this was written
    on."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)  # rewriting a profile mid-test is a fresh DB
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, "
                "title LONGVARCHAR, visit_count INTEGER DEFAULT 0, "
                "typed_count INTEGER DEFAULT 0, last_visit_time INTEGER, "
                "hidden INTEGER DEFAULT 0)")
    con.executemany("INSERT INTO urls (url, title, visit_count, last_visit_time, hidden, "
                    "typed_count) VALUES (?, ?, ?, ?, ?, ?)",
                    [tuple(row) + (0,) * (6 - len(row)) for row in rows])
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

    def test_the_same_url_in_two_profiles_is_one_row(self):
        # This used to assert the opposite, and was right to: while the
        # profile came from the ROW, two rows were two different answers. Now
        # the key decides the profile, so they are one answer drawn twice.
        now = time.time()
        make_history(self.chrome / "Default" / "History",
                     [("https://mail.google.com/", "Inbox", 400, webkit(now), 0, 12)])
        make_history(self.chrome / "Profile 1" / "History",
                     [("https://mail.google.com/", "Inbox", 3, webkit(now), 0, 1)])
        rows = [r for r in namer.build_history() if r["url"] == "https://mail.google.com/"]
        self.assertEqual(len(rows), 1)
        # Signals add up: one person typed it from both accounts.
        self.assertEqual(rows[0]["visits"], 403)
        self.assertEqual(rows[0]["typedCount"], 13)
        # ...and the row still says where it has been seen, so the UI can show
        # that Shift+Enter is meaningful here.
        self.assertEqual(sorted(rows[0]["profiles"]), ["Default", "Profile 1"])
        self.assertEqual(sorted(rows[0]["profileNames"]), ["Andy", "tradewinds.school"])

    def test_a_merged_row_keeps_the_best_ranked_origin_for_its_icon(self):
        now = time.time()
        make_history(self.chrome / "Default" / "History",
                     [("https://mail.google.com/", "Inbox", 2, webkit(now), 0)])
        make_history(self.chrome / "Profile 1" / "History",
                     [("https://mail.google.com/", "Work inbox", 900, webkit(now), 0)])
        row = [r for r in namer.build_history() if r["url"] == "https://mail.google.com/"][0]
        self.assertEqual(row["profile"], "Profile 1")
        self.assertEqual(row["title"], "Work inbox")

    def test_a_url_in_one_profile_is_untouched_by_the_merge(self):
        make_history(self.chrome / "Default" / "History",
                     [("https://a.example/", "a", 5, webkit(time.time()), 0)])
        row = namer.build_history()[0]
        self.assertEqual(row["profiles"], ["Default"])
        self.assertEqual(row["visits"], 5)

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


class TestTypedHistory(ChromeDirTest):
    """typed_count -- how often a URL was reached by TYPING it -- is what turns
    a history search into an address bar, so it has to reach the index intact
    and it must not be something a recency sample can cut."""

    def setUp(self):
        super().setUp()
        self.write_local_state({"Default": {"name": "Andy"}})

    def test_typed_count_reaches_the_row(self):
        now = time.time()
        make_history(self.chrome / "Default" / "History",
                     [("https://gmail.com/", "Inbox", 98, webkit(now), 0, 90)])
        rows = namer.build_history()
        self.assertEqual(rows[0]["typedCount"], 90)

    def test_a_url_nobody_typed_reports_zero_rather_than_nothing(self):
        make_history(self.chrome / "Default" / "History",
                     [("https://example.com/", "page", 3, webkit(time.time()), 0)])
        self.assertEqual(namer.build_history()[0]["typedCount"], 0)

    def test_a_typed_url_survives_a_recency_sample_that_excludes_it(self):
        # The shape this exists for: an afternoon of link-following buries a
        # destination typed every week for years. Ordered by last visit alone
        # the typed row is not even a candidate.
        now = time.time()
        rows = self.rows(400, visits=2, when=now)
        rows.append(("https://gmail.com/", "Inbox", 98, webkit(now - 86400 * 30), 0, 90))
        make_history(self.chrome / "Default" / "History", rows)
        kept = namer.build_history(limit=50, floor=10)
        self.assertIn("https://gmail.com/", [r["url"] for r in kept])
        self.assertEqual(kept[0]["url"], "https://gmail.com/",
                         "the most-typed URL must outrank a fresh recency sample")

    def test_typed_rows_are_ordered_by_typed_count_ahead_of_the_blend(self):
        now = time.time()
        make_history(self.chrome / "Default" / "History", [
            ("https://news.google.com/", "Google News", 53, webkit(now), 0, 39),
            ("https://busy.example/", "busy", 5000, webkit(now), 0, 0),
            ("https://calendar.google.com/", "Calendar", 175, webkit(now), 0, 74),
        ])
        self.assertEqual([r["domain"] for r in namer.build_history()],
                         ["calendar.google.com", "news.google.com", "busy.example"])

    def test_a_typed_url_is_never_padded_in_from_the_hidden_pile(self):
        # Hidden rows stay a floor top-up, typed or not: a redirect Chrome
        # refuses to autocomplete is not a destination.
        make_history(self.chrome / "Default" / "History",
                     [("https://redirect.example/", "r", 1, webkit(time.time()), 1, 40)]
                     + self.rows(30, visits=4))
        kept = namer.build_history(limit=20, floor=0)
        self.assertNotIn("https://redirect.example/", [r["url"] for r in kept])


class TestProfileOrder(ChromeDirTest):
    """Which profile Enter opens a link in. The UI reads position 0 and never
    asks a history row, so the order here IS the rule."""

    def setUp(self):
        super().setUp()
        self.write_local_state({"Default": {"name": "Andy"},
                                "Profile 1": {"name": "tradewinds.school"}})
        make_history(self.chrome / "Default" / "History", [])
        make_history(self.chrome / "Profile 1" / "History", [])

    def test_chromes_own_default_leads_when_nothing_is_configured(self):
        self.assertEqual(namer.omnibox_profiles(),
                         [{"dir": "Default", "name": "Andy", "primary": True},
                          {"dir": "Profile 1", "name": "tradewinds.school", "primary": False}])

    def test_the_config_key_takes_either_the_directory_or_the_name(self):
        for key in ("Profile 1", "tradewinds.school", "TRADEWINDS.SCHOOL"):
            first = namer.omnibox_profiles(primary=key)[0]
            self.assertEqual((first["dir"], first["primary"]), ("Profile 1", True), key)

    def test_an_unknown_primary_falls_back_rather_than_failing(self):
        # A config (or a keybind) naming a profile that has since been deleted
        # must still leave a usable omnibox.
        self.assertEqual(namer.omnibox_profiles(primary="Profile 9")[0]["dir"], "Default")

    def test_the_index_ships_the_order_and_the_search_engine(self):
        payload = namer.build_omnibox_index(primary="Profile 1")
        self.assertEqual([p["dir"] for p in payload["profiles"]], ["Profile 1", "Default"])
        self.assertIn("{searchTerms}", payload["search"]["template"])


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


class TestWindowProfile(ChromeDirTest):
    """Which Chrome profile a WINDOW belongs to -- the question nothing
    outside Chrome could answer, since every profile shares one browser
    process and one window class."""

    def setUp(self):
        super().setUp()
        self.write_local_state({
            "Default": {"name": "Andy", "user_name": "andyszy@gmail.com",
                        "profile_color_seed": -3413569},
            "Profile 1": {"name": "tradewinds.school", "user_name": "andy@tradewinds.school",
                          "profile_color_seed": -336013},
        })
        make_history(self.chrome / "Default" / "History", [])
        make_history(self.chrome / "Profile 1" / "History", [])
        self.meta = namer.chrome_profile_meta()

    def test_chip_colours_are_derived_from_chromes_own_seed(self):
        # The same values the window title bars use, so a thumbnail and its
        # window read as the same account.
        self.assertEqual(namer.profile_chip_colors(-3413569)[0], "#EAF5E6")
        self.assertEqual(namer.profile_chip_colors(-336013)[0], "#FBF6DF")
        # Text is the same hue, dark and nearly neutral -- legible on the chip
        # rather than a saturated ink.
        self.assertEqual(namer.profile_chip_colors(-3413569)[1], "#353F31")
        self.assertIsNone(namer.profile_chip_colors(None))

    def test_a_site_app_window_carries_its_profile_in_the_class(self):
        # Free and exact, with no extension involved at all -- and every
        # window here is becoming an app-mode window.
        got = namer.window_profile("chrome-gmail.com__-Profile_1", None, self.meta)
        self.assertEqual(got["profile"], "Profile 1")
        self.assertEqual(got["profileName"], "tradewinds.school")
        self.assertEqual(got["profileColor"], "#FBF6DF")

    def test_a_tabbed_window_is_attributed_by_the_reported_email(self):
        got = namer.window_profile("google-chrome", {"email": "ANDYSZY@gmail.com"}, self.meta)
        self.assertEqual((got["profile"], got["profileName"]), ("Default", "Andy"))

    def test_an_unattributable_window_gets_nothing(self):
        # A wrong work/personal marker is worse than no marker, so every
        # unknown case has to come back empty rather than fall back to a
        # default profile.
        self.assertEqual(namer.window_profile("google-chrome", None, self.meta), {})
        self.assertEqual(namer.window_profile("google-chrome", {"email": ""}, self.meta), {})
        self.assertEqual(namer.window_profile("org.omarchy.claude", None, self.meta), {})
        self.assertEqual(
            namer.window_profile("chrome-gmail.com__-Profile_9", None, self.meta), {})

    def test_a_profile_with_no_colour_seed_still_names_itself(self):
        self.write_local_state({"Default": {"name": "Andy"}})
        meta = namer.chrome_profile_meta()
        got = namer.window_profile("chrome-mail.google.com__-Default", None, meta)
        self.assertEqual(got, {"profile": "Default", "profileName": "Andy"})


class TestTabFileMerge(unittest.TestCase):
    """load_chrome_tabs() merges one file per extension instance."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.now = 1_000_000.0

    def write(self, name, payload):
        (self.dir / name).write_text(json.dumps(payload))

    def report(self, instance, windows, age=0.0):
        return {"instanceId": instance, "updatedAt": self.now - age, "windows": windows}

    @staticmethod
    def window(wid, title, updated=None):
        win = {"id": wid, "activeTitle": title,
               "tabs": [{"title": title, "url": f"https://example.com/{wid}", "active": True}]}
        if updated is not None:
            win["updatedAt"] = updated
        return win

    def load(self):
        return namer.load_chrome_tabs(state_dir=self.dir, now=self.now)

    def test_both_profiles_are_visible_at_once(self):
        self.write("chrome-tabs.aaa.json", self.report("aaa", [self.window(1, "personal")]))
        self.write("chrome-tabs.bbb.json", self.report("bbb", [self.window(2, "work")]))
        titles = sorted(w["activeTitle"] for w in self.load())
        self.assertEqual(titles, ["personal", "work"])

    def test_a_stale_file_is_ignored(self):
        self.write("chrome-tabs.aaa.json", self.report("aaa", [self.window(1, "live")]))
        self.write("chrome-tabs.bbb.json",
                   self.report("bbb", [self.window(2, "gone")],
                               age=namer.CHROME_TABS_MAX_AGE + 1))
        self.assertEqual([w["activeTitle"] for w in self.load()], ["live"])

    def test_the_legacy_single_file_still_reads(self):
        self.write("chrome-tabs.json", {"updatedAt": self.now,
                                        "windows": [self.window(1, "old host")]})
        self.assertEqual([w["activeTitle"] for w in self.load()], ["old host"])

    def test_a_window_stale_inside_a_fresh_file_is_dropped(self):
        # The shared-file path gives each window its own updatedAt, so one
        # instance's closed window ages out without taking the file with it.
        self.write("chrome-tabs.json", {
            "updatedAt": self.now,
            "windows": [self.window(1, "live", updated=self.now),
                        self.window(2, "closed", updated=self.now - namer.CHROME_TABS_MAX_AGE - 1)],
        })
        self.assertEqual([w["activeTitle"] for w in self.load()], ["live"])

    def test_the_same_window_reported_twice_is_deduplicated(self):
        self.write("chrome-tabs.json", {"updatedAt": self.now - 30,
                                        "windows": [self.window(7, "stale title")]})
        self.write("chrome-tabs.aaa.json", self.report("aaa", [self.window(7, "fresh title")]))
        windows = self.load()
        self.assertEqual([w["activeTitle"] for w in windows], ["fresh title"])

    def test_nothing_fresh_reads_as_no_report_at_all(self):
        self.write("chrome-tabs.aaa.json",
                   self.report("aaa", [self.window(1, "x")], age=namer.CHROME_TABS_MAX_AGE + 1))
        self.assertIsNone(self.load())
        self.assertIsNone(namer.load_chrome_tabs(state_dir=self.dir / "nope", now=self.now))


class TestMatchChromeWindows(unittest.TestCase):

    @staticmethod
    def win(title, url, instance="aaa", updated=100.0):
        return {"activeTitle": title, "instance": instance, "updatedAt": updated,
                "tabs": [{"title": title, "url": url, "active": True}]}

    def test_unambiguous_titles_still_match(self):
        windows = [self.win("Gmail", "https://mail.google.com/")]
        self.assertEqual(namer.match_chrome_windows([(0, "Gmail")], windows),
                         {0: windows[0]})

    def test_the_same_title_in_two_profiles_prefers_the_fresher_report(self):
        old = self.win("Untitled document", "https://docs.google.com/1", "aaa", 100.0)
        new = self.win("Untitled document", "https://docs.google.com/2", "bbb", 160.0)
        matched = namer.match_chrome_windows([(0, "Untitled document")], [old, new])
        self.assertEqual(matched, {0: new})

    def test_an_equally_fresh_tie_is_left_unmatched(self):
        a = self.win("New Tab", "https://a.example/", "aaa", 100.0)
        b = self.win("New Tab", "https://b.example/", "bbb", 100.0)
        self.assertEqual(namer.match_chrome_windows([(0, "New Tab")], [a, b]), {})

    def test_an_equally_fresh_tie_whose_tabs_are_identical_matches(self):
        # Two reports of the same window content: whichever is picked, every
        # field the caller reads is the same, so there is nothing to guess.
        a = self.win("Gmail", "https://mail.google.com/", "aaa", 100.0)
        b = self.win("Gmail", "https://mail.google.com/", "bbb", 100.0)
        self.assertEqual(namer.match_chrome_windows([(0, "Gmail")], [a, b]), {0: a})

    def test_two_hyprland_windows_with_one_title_stay_unmatched(self):
        windows = [self.win("Gmail", "https://mail.google.com/")]
        self.assertEqual(
            namer.match_chrome_windows([(0, "Gmail"), (1, "Gmail")], windows), {})


HOST = Path.home() / ".config/omarchy/chrome-extensions/literate-tabs-host"


@unittest.skipUnless(HOST.exists(), f"native messaging host not installed at {HOST}")
class TestNativeHost(unittest.TestCase):
    """The other half of the join, driven for real: the host binary Chrome
    launches, fed Chrome's own framing on stdin. One host process per profile
    is exactly how Chrome runs it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.state = self.home / ".local/state/literate"
        self.addCleanup(self.tmp.cleanup)

    def run_host(self, *messages):
        """One host process, given these messages, then a closed pipe -- the
        same shape as a profile's extension connecting and going away."""
        payload = b"".join(
            struct.pack("<I", len(body)) + body
            for body in (json.dumps(m).encode() for m in messages))
        env = {**os.environ, "HOME": str(self.home)}
        done = subprocess.run([sys.executable, str(HOST)], input=payload,
                              capture_output=True, env=env, timeout=30)
        self.assertEqual(done.stdout, b"", "a host must never write to stdout")
        return done

    @staticmethod
    def message(instance, wid, title):
        body = {"windows": [{"id": wid, "activeTitle": title,
                             "tabs": [{"title": title, "url": f"https://example.com/{wid}",
                                       "active": True}]}]}
        if instance:
            body["instanceId"] = instance
        return body

    def titles(self):
        windows = namer.load_chrome_tabs(state_dir=self.state) or []
        return sorted(w["activeTitle"] for w in windows)

    def test_two_instances_write_two_files_and_both_are_seen(self):
        self.run_host(self.message("aaaa1111", 1, "personal"))
        self.run_host(self.message("bbbb2222", 2, "work"))
        self.assertEqual(sorted(p.name for p in self.state.glob("chrome-tabs*.json")),
                         ["chrome-tabs.aaaa1111.json", "chrome-tabs.bbbb2222.json"])
        self.assertEqual(self.titles(), ["personal", "work"])

    def test_an_instance_replaces_only_its_own_file(self):
        self.run_host(self.message("aaaa1111", 1, "personal"))
        self.run_host(self.message("bbbb2222", 2, "work"))
        self.run_host(self.message("aaaa1111", 1, "personal, renamed"))
        self.assertEqual(self.titles(), ["personal, renamed", "work"])

    def test_hosts_with_no_instance_id_share_the_file_instead_of_erasing_it(self):
        # Extension 1.0 in two profiles: this is the bug, driven for real.
        self.run_host(self.message(None, 1, "personal"))
        self.run_host(self.message(None, 2, "work"))
        self.assertEqual([p.name for p in self.state.glob("chrome-tabs*.json")],
                         ["chrome-tabs.json"])
        self.assertEqual(self.titles(), ["personal", "work"])

    def test_a_shared_window_is_updated_in_place_not_duplicated(self):
        self.run_host(self.message(None, 1, "personal"))
        self.run_host(self.message(None, 2, "work"))
        self.run_host(self.message(None, 1, "personal, navigated"))
        self.assertEqual(self.titles(), ["personal, navigated", "work"])

    def test_a_malformed_frame_does_not_take_the_state_with_it(self):
        self.run_host(self.message("aaaa1111", 1, "personal"))
        env = {**os.environ, "HOME": str(self.home)}
        subprocess.run([sys.executable, str(HOST)], input=struct.pack("<I", 40) + b"{not json",
                       capture_output=True, env=env, timeout=30)
        self.assertEqual(self.titles(), ["personal"])

    def test_an_instance_id_is_never_taken_straight_into_a_path(self):
        self.run_host(self.message("../../../etc/passwd", 1, "sneaky"))
        # Rejected as an id, so it took the shared path instead.
        self.assertEqual([p.name for p in self.state.glob("chrome-tabs*.json")],
                         ["chrome-tabs.json"])


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0], *sys.argv[1:]])
