#!/usr/bin/env python3
"""Unit tests for Omnibox.js, the matching library Shelf.qml and Triage.qml
share.

    python3 tools/test-omnibox.py

The library is `.pragma library` -- pure functions, no QML context, every
input passed in -- which is exactly what makes it testable without a
compositor. It is evaluated in node (the one thing on this machine that can
run it outside Quickshell) with that one pragma line stripped, and the
assertions live here beside the daemon's own tests rather than in a second
test framework. The daemon itself is loaded the way tools/test-chrome.py loads
it, through SourceFileLoader, because the two halves of a ranking decision --
which rows reach the index, and how the index is ordered once queried -- are
only correct together.
"""

import importlib.machinery
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIBRARY = REPO / "Omnibox.js"
NODE = shutil.which("node")


def load_daemon():
    path = REPO / "bin" / "literate-workspace-namer"
    loader = importlib.machinery.SourceFileLoader("literate_namer", str(path))
    spec = importlib.util.spec_from_loader("literate_namer", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


namer = load_daemon()
_LOG = tempfile.NamedTemporaryFile(prefix="literate-test-", suffix=".log", delete=False)
namer.LOG_PATH = Path(_LOG.name)


@unittest.skipUnless(NODE, "node is needed to evaluate Omnibox.js outside Quickshell")
class OmniboxJsTest(unittest.TestCase):
    """Calls one function in Omnibox.js and returns its result as Python."""

    def call(self, expression, **bindings):
        source = LIBRARY.read_text().replace(".pragma library", "", 1)
        driver = (source + "\n"
                  + "".join(f"var {name} = {json.dumps(value)};\n"
                            for name, value in bindings.items())
                  + f"console.log(JSON.stringify({expression}));\n")
        done = subprocess.run([NODE, "-e", driver], capture_output=True, text=True,
                              timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)


def row(domain, *, title=None, typed=0, visits=0, last=0, url=None):
    return {"domain": domain, "title": title if title is not None else domain,
            "url": url or f"https://{domain}/", "typedCount": typed,
            "visits": visits, "lastVisit": last}


class TestHistoryRanking(OmniboxJsTest):
    """The behavioural test of the ranking change: typing two letters has to
    land on the place those two letters are the name of."""

    def order(self, query, rows):
        hits = self.call("matchHistory(query, { history: history })",
                         query=query, history=rows)
        return [h["domain"] for h in hits]

    def test_typed_count_beats_visits_and_recency(self):
        # gmail.com typed 90 times against the busiest and freshest page whose
        # title merely contains "gm".
        rows = [row("mail-archive.example", title="gm digest", visits=5000, last=2_000_000_000),
                row("gmail.com", title="Inbox", typed=90, visits=98, last=1_000_000_000)]
        self.assertEqual(self.order("gm", rows)[0], "gmail.com")

    def test_a_prefix_match_still_beats_a_mid_string_one(self):
        # The rank tier is checked BEFORE typed count, so no amount of typing
        # promotes a match buried inside a word.
        rows = [row("example.com", title="a bugmail thread", typed=500),
                row("gmail.com", title="Inbox", typed=1)]
        self.assertEqual(self.order("gm", rows)[0], "gmail.com")

    def test_a_word_boundary_match_beats_a_mid_string_one(self):
        rows = [row("x.example", title="highcal readings", typed=99),
                row("y.example", title="my cal for today", typed=0)]
        self.assertEqual(self.order("cal", rows), ["y.example", "x.example"])

    def test_visits_then_recency_break_a_tie_among_untyped_rows(self):
        rows = [row("a.example", title="news a", visits=2, last=50),
                row("b.example", title="news b", visits=9, last=10),
                row("c.example", title="news c", visits=2, last=90)]
        self.assertEqual(self.order("news", rows), ["b.example", "c.example", "a.example"])

    def test_a_row_with_no_typed_count_at_all_still_ranks(self):
        # An index written before this change, or a row from a profile whose
        # History predates typed_count: absent must read as zero, not NaN.
        stale = {"domain": "old.example", "title": "old", "url": "https://old.example/",
                 "visits": 3, "lastVisit": 1}
        hits = self.call("matchHistory(query, { history: history })",
                         query="old", history=[stale])
        self.assertEqual(len(hits), 1)


GOOGLE = {"name": "Google", "template": "https://www.google.com/search?q={searchTerms}"}


class TestUrlVersusSearch(OmniboxJsTest):
    """The rule the pinned row lives by: is this text a place or a question?
    With no address bar left, getting it wrong means either a search for
    "localhost:3000" or a navigation to "3.5"."""

    def action(self, query, search=GOOGLE):
        return self.call("urlOrSearch(query, search)", query=query, search=search)

    def test_a_bare_domain_with_a_path_is_a_place(self):
        self.assertEqual(self.action("github.com/foo"),
                         {"kind": "open", "url": "https://github.com/foo",
                          "engine": "Open", "label": "Open https://github.com/foo"})

    def test_a_host_with_a_port_is_a_place_and_localhost_is_not_https(self):
        # https://localhost:3000 fails on essentially every dev server, and
        # http to loopback is not a downgrade anyone can intercept.
        self.assertEqual(self.action("localhost:3000")["url"], "http://localhost:3000")
        self.assertEqual(self.action("127.0.0.1:8080")["url"], "http://127.0.0.1:8080")
        self.assertEqual(self.action("mini.local:5900")["url"], "http://mini.local:5900")

    def test_an_explicit_scheme_is_passed_through_untouched(self):
        for url in ("https://x.dev/a?b=1", "http://x.dev", "file:///tmp/x.html"):
            self.assertEqual(self.action(url)["url"], url)

    def test_words_and_version_numbers_are_searches(self):
        for query in ("gm", "hello world", "3.5", "u.s.", "why is the sky blue"):
            self.assertEqual(self.action(query)["kind"], "search", query)

    def test_a_search_goes_through_the_users_own_engine(self):
        ddg = {"name": "DuckDuckGo", "template": "https://duckduckgo.com/?q={searchTerms}"}
        action = self.action("hello world", ddg)
        self.assertEqual(action["url"], "https://duckduckgo.com/?q=hello%20world")
        self.assertEqual(action["engine"], "DuckDuckGo")

    def test_google_is_the_fallback_and_only_the_fallback(self):
        # A missing or unreadable index must still leave Enter working.
        self.assertEqual(self.action("hello", None)["url"],
                         "https://www.google.com/search?q=hello")
        self.assertEqual(self.action("hello", {"name": "", "template": "nonsense"})["url"],
                         "https://www.google.com/search?q=hello")

    def test_an_empty_query_has_no_action_at_all(self):
        self.assertIsNone(self.action(""))
        self.assertIsNone(self.action("   "))


class TestSearchEngineFromChrome(unittest.TestCase):
    """The daemon half: what the index ships as the search engine."""

    def test_chromes_own_google_template_is_reduced_to_a_usable_one(self):
        raw = ("{google:baseURL}search?q={searchTerms}&{google:RLZ}"
               "{google:originalQueryForSuggestion}ie={inputEncoding}")
        self.assertEqual(namer.clean_search_template(raw),
                         "https://www.google.com/search?q={searchTerms}")

    def test_a_plain_third_party_template_survives_intact(self):
        self.assertEqual(namer.clean_search_template("https://duckduckgo.com/?q={searchTerms}"),
                         "https://duckduckgo.com/?q={searchTerms}")

    def test_a_template_that_cannot_be_honoured_is_refused(self):
        # No search terms, an unexpandable host, or not a web URL at all: the
        # caller falls back to Google rather than building a broken request.
        for raw in ("https://example.com/?a=b", "{google:unknown}/search?q={searchTerms}",
                    "chrome://history/?q={searchTerms}", ""):
            self.assertEqual(namer.clean_search_template(raw), "", raw)

    def test_no_chrome_preferences_still_yields_a_working_engine(self):
        self.assertEqual(namer.chrome_search_engine("nonexistent-profile"),
                         namer.GOOGLE_SEARCH)


class TestProfileMark(OmniboxJsTest):
    """The initials a history row shows for the account(s) it is known in."""

    def mark(self, row):
        return self.call("profileMark(row)", row=row)

    def test_two_profiles_read_as_two_initials(self):
        self.assertEqual(self.mark({"profileNames": ["Andy", "tradewinds.school"]}), "AT")

    def test_one_profile_reads_as_one(self):
        self.assertEqual(self.mark({"profileNames": ["Andy"]}), "A")
        self.assertEqual(self.mark({"profileName": "Andy"}), "A")

    def test_an_array_like_that_is_not_an_Array_still_counts(self):
        # A row arrives through a ListView model, where QML has turned the JS
        # object into a QVariantMap and its nested array into something that
        # indexes and has .length but fails Array.isArray. Asking isArray drew
        # a single initial on every merged row; this is that bug, pinned.
        got = self.call("profileMark({ profileNames: arrayLike, profileName: 'Andy' })",
                        arrayLike={"0": "Andy", "1": "tradewinds.school", "length": 2})
        self.assertEqual(got, "AT")

    def test_no_profile_at_all_is_empty_rather_than_invented(self):
        self.assertEqual(self.mark({}), "")


class TestIndexAndRankingAgree(unittest.TestCase):
    """The index and the ranking are one decision in two files."""

    def test_the_daemon_writes_the_field_the_library_ranks_on(self):
        self.assertIn('"typedCount": typed',
                      (REPO / "bin" / "literate-workspace-namer").read_text())
        self.assertIn("typedCount", LIBRARY.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0], *sys.argv[1:]])
