#!/usr/bin/env python3
"""Drive bin/literate-mcp over real stdio, the way a client does.

    python3 tools/test-mcp.py                 # read tools only, no writes
    python3 tools/test-mcp.py --writes        # also exercise the write tools

There is no `mcp` package here to lend a test client, and the server is
hand-rolled, so the only honest test is to speak the protocol at it: spawn it
as a subprocess, write newline-delimited JSON-RPC on its stdin, read frames off
its stdout. A tool that was never called is a tool that does not work.

--writes touches the live desktop, so it is deliberately opt-in and confines
itself to things it can undo: it pins and unpins a workspace nobody is on,
opens one Chrome --app= window and closes it by address (the one proven-safe
window to create), and never moves, closes or focuses anything it did not
create. Never point it at a workspace somebody is working on.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SERVER = Path(os.environ.get("LITERATE_MCP") or REPO / "bin" / "literate-mcp")
# Two workspaces nobody is likely to be on: one to open the throwaway Chrome
# window onto, one to move it to. Never point these at a workspace in use --
# open_url's exec rule is silent, but focus_window is not and cannot be.
SCRATCH_WS = "9"
SCRATCH_WS2 = "8"


class Client:
    def __init__(self, command):
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=None,
                                     text=True, bufsize=1)
        self.next_id = 0

    def send(self, method, params=None, notify=False):
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if not notify:
            self.next_id += 1
            payload["id"] = self.next_id
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        if notify:
            return None
        line = self.proc.stdout.readline()
        if not line:
            raise SystemExit("server closed the pipe")
        return json.loads(line)

    def call(self, name, arguments=None):
        reply = self.send("tools/call", {"name": name,
                                         "arguments": arguments or {}})
        result = reply.get("result") or {}
        text = "".join(c.get("text", "") for c in result.get("content") or [])
        if result.get("isError"):
            return {"_error": text}
        try:
            return json.loads(text)
        except ValueError:
            return {"_text": text}

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        self.proc.wait(timeout=10)


def show(label, payload, cap=1400):
    blob = json.dumps(payload, indent=2, ensure_ascii=False)
    if len(blob) > cap:
        blob = blob[:cap] + f"\n… [{len(blob)} bytes total]"
    print(f"\n### {label}\n{blob}")


def current_workspace(client):
    return client.call("list_workspaces")["focusedWorkspaces"][0]


def find_app_window(client, needle):
    """The throwaway Chrome --app window, by the host Chrome puts in its class
    ("chrome-example.com__-Default"), with the workspace it is on. Identified
    by class rather than title because the title changes when it navigates."""
    for ws in client.call("list_workspaces")["workspaces"]:
        for w in ws["windows"]:
            if needle in (w.get("class") or "").lower():
                return {**w, "workspace": ws["id"]}
    return None


def main():
    writes = "--writes" in sys.argv
    client = Client([sys.executable, str(SERVER)])

    init = client.send("initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "test-mcp", "version": "0"}})
    show("initialize", init)
    assert init["result"]["protocolVersion"] == "2025-06-18", init
    # An unsupported version must come back as ours, not echoed blindly.
    probe = Client([sys.executable, str(SERVER)])
    old = probe.send("initialize", {"protocolVersion": "1999-01-01",
                                    "capabilities": {}, "clientInfo": {}})
    assert old["result"]["protocolVersion"] == "2025-06-18", old
    probe.close()

    client.send("notifications/initialized", {}, notify=True)
    show("ping", client.send("ping"))

    listed = client.send("tools/list")
    names = [t["name"] for t in listed["result"]["tools"]]
    print("\n### tools/list\n" + "\n".join(
        f"  {t['name']}: {t['description'].split('.')[0]}."
        for t in listed["result"]["tools"]))

    show("list_workspaces", client.call("list_workspaces"))
    show("list_chrome_profiles", client.call("list_chrome_profiles"))
    show("list_chrome_tabs", client.call("list_chrome_tabs"))
    show("get_triage", client.call("get_triage"))
    show("search_history q=gmail", client.call("search_history",
                                               {"query": "gmail", "limit": 3}))
    show("search_conversations q=bar", client.call("search_conversations",
                                                   {"query": "bar", "limit": 3}))

    # Refusals are behaviour too, and the cheapest kind to test.
    show("close_window without confirm",
         client.call("close_window", {"address": "0xdeadbeef", "confirm": False}))
    show("move_window bad address",
         client.call("move_window", {"address": "nonsense", "workspace": "2"}))
    show("unknown tool", client.call("no_such_tool"))
    show("unknown method", client.send("wat/ever"))

    if writes:
        home = client.call("list_workspaces")["focusedWorkspaces"][0]
        print(f"\n(the user is on workspace {home}; every switch below is undone)")

        show(f"rename_workspace {SCRATCH_WS}",
             client.call("rename_workspace", {"id": SCRATCH_WS,
                                              "name": "mcp test",
                                              "icon": "flask"}))
        show(f"unpin_workspace {SCRATCH_WS}",
             client.call("unpin_workspace", {"id": SCRATCH_WS}))

        show("open_url", client.call("open_url",
                                     {"url": "https://example.com/",
                                      "workspace": SCRATCH_WS}))
        print("\n(waiting for the Chrome window to map)")
        time.sleep(4)
        mine = find_app_window(client, "example.com")
        show("the window open_url made", mine)
        if not mine:
            print("!! open_url made no window we could find; stopping here so "
                  "nothing else acts on a window we cannot identify")
            client.close()
            return
        assert current_workspace(client) == home, \
            "open_url dragged the user off their workspace; the exec rule is " \
            "supposed to be silent"
        print(f"  user still on {home} after open_url: correct")

        show("move_window (follow=false)", client.call(
            "move_window", {"address": mine["address"],
                            "workspace": SCRATCH_WS2, "follow": False}))
        time.sleep(1)
        mine = find_app_window(client, "example.com")
        assert mine and mine["workspace"] == SCRATCH_WS2, mine
        assert current_workspace(client) == home, \
            "move_window with follow=false took the user along"
        print(f"  window on {SCRATCH_WS2}, user still on {home}: correct")

        # The one test that has to move the user. Undone immediately.
        show("focus_window", client.call("focus_window",
                                         {"address": mine["address"]}))
        time.sleep(0.5)
        print(f"  focused workspace is now {current_workspace(client)} "
              f"(expected {SCRATCH_WS2})")
        show("focus_workspace (back)", client.call("focus_workspace", {"id": home}))
        time.sleep(0.5)
        assert current_workspace(client) == home, "failed to put the user back!"
        print(f"  user back on {home}: correct")

        show("navigate_window", client.call(
            "navigate_window", {"address_or_title": mine["address"],
                                "url": "https://example.org/"}))
        time.sleep(3)
        print(f"  focused workspace after navigate: {current_workspace(client)} "
              "(the extension focuses the window it navigates)")
        client.call("focus_workspace", {"id": home})
        time.sleep(0.5)
        assert current_workspace(client) == home, "failed to put the user back!"

        show("close_window", client.call(
            "close_window", {"address": mine["address"], "confirm": True}))
        time.sleep(1)
        assert find_app_window(client, "example.com") is None, \
            "the throwaway window is still open"
        assert current_workspace(client) == home, "closing moved the user"
        print(f"  window gone, user on {home}: correct")

    client.close()
    print("\nall frames answered; tools exercised: " + ", ".join(names))


if __name__ == "__main__":
    main()
