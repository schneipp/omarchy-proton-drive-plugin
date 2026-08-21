#!/usr/bin/env python3
"""Hostile-input tests for the Proton Drive plugin.

The planner tests ask "does a sync decide the right thing"; this file asks the
other question: what happens when the data is not friendly. Everything a folder
contains — names, sizes, timestamps — comes from whoever owns or shared it, and
the plugin's job is to stay inside the folder the user paired no matter what is
in there.

Nothing here touches the network, a Proton account, or any file outside a
temporary directory this script makes and removes.

    python3 tests/test_security.py
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, filename):
    path = os.path.join(HERE, os.pardir, "bin", filename)
    module = importlib.util.module_from_spec(
        importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path)))
    module.__spec__.loader.exec_module(module)
    return module


S = load("syncmod", "omarchy-proton-drive-sync")
pd = S.pd

FAILED = []


def check(label, got, want):
    if got != want:
        FAILED.append("%s\n    got:  %r\n    want: %r" % (label, got, want))
        print("FAIL %s" % label)
    else:
        print("ok   %s" % label)


def raises(fn, *args):
    try:
        fn(*args)
    except Exception:
        return True
    return False


# --- names -----------------------------------------------------------------
#
# A name is one path component or it is nothing. Traversal, separators, control
# characters and absurd lengths are all refused at this single gate.

for bad in ("", ".", "..", "../outside.txt", "a/b", "/etc/passwd", "x\0y",
            "line\nbreak", "tab\there", "bell\a", "x" * 256):
    check("rejects the remote name %r" % bad[:40], pd.safe_name(bad), False)

for good in ("notes.txt", "..hidden", "a..b", "...", "-rf", "Ordner mit Leerzeichen",
             "Grüße.pdf", "喜.txt", "x" * 255):
    check("accepts the remote name %r" % good[:40], pd.safe_name(good), True)

# --- paths handed to another program ---------------------------------------

for bad in ("", "relative/x", "-rf", "--json", "/with\nbreak", "/nul\0byte", "/" + "x" * 4096):
    check("rejects the remote path %r" % bad[:40], pd.safe_remote_path(bad), False)
check("accepts an ordinary remote path", pd.safe_remote_path("/my-files/Docs"), True)
check("accepts a remote path holding an escaped slash",
      pd.safe_remote_path("/my-files/two\\/parts"), True)

for bad in ("", "relative", "-rf", "/tmp/with\nbreak"):
    check("rejects the local path %r" % bad[:40], pd.safe_local_path(bad), False)
check("accepts an ordinary local path", pd.safe_local_path("/home/x/Sync"), True)

# The one choke point every CLI call goes through.
check("run_cli refuses an argument with a newline",
      raises(pd.run_cli, ["filesystem", "list", "/x\ny"], 5), True)
check("run_cli refuses a non-string argument", raises(pd.run_cli, ["list", 7], 5), True)

# --- local paths built from remote keys ------------------------------------

ROOT = tempfile.mkdtemp(prefix="pd-sec-")
try:
    check("maps a plain key under the pair root",
          S.local_path(ROOT, "sub/file.txt"), os.path.join(ROOT, "sub", "file.txt"))
    check("an empty key is the root itself", S.local_path(ROOT, ""), ROOT)

    for bad in ("../outside.txt", "sub/../../outside.txt", "..", "/etc/passwd",
                "sub//../..", "a/../../b", "sub/\0/x"):
        check("refuses to build a local path from %r" % bad,
              raises(S.local_path, ROOT, bad), True)

    # A symlink is the way out that pure string arithmetic does not see.
    os.mkdir(os.path.join(ROOT, "inside"))
    escape = tempfile.mkdtemp(prefix="pd-sec-out-")
    os.symlink(escape, os.path.join(ROOT, "away"))
    check("refuses to follow a symlink out of the pair",
          raises(S.local_path, ROOT, "away/file.txt"), True)
    check("still allows an ordinary folder next to it",
          S.local_path(ROOT, "inside/file.txt"), os.path.join(ROOT, "inside", "file.txt"))

    # The pair root itself may be a link — that is how an external disk is
    # usually reached — and everything under it must still work.
    linked_root = os.path.join(escape, "as-link")
    os.symlink(ROOT, linked_root)
    check("a pair root that is itself a symlink is fine",
          S.local_path(linked_root, "inside/file.txt"),
          os.path.join(linked_root, "inside", "file.txt"))
finally:
    shutil.rmtree(ROOT, ignore_errors=True)

# --- the scan drops what it cannot handle ----------------------------------

LISTING = {
    "/r": [{"name": {"ok": True, "value": ".."}, "type": "folder"},
           {"name": {"ok": True, "value": "../evil.txt"}, "type": "file"},
           {"name": {"ok": True, "value": "sneak\nier.txt"}, "type": "file"},
           {"name": {"ok": True, "value": "notes.txt"}, "type": "file",
            "activeRevision": {"claimedSize": 3}},
           {"name": {"ok": True, "value": "sub"}, "type": "folder"}],
    "/r/sub": [{"name": {"ok": True, "value": "deep.txt"}, "type": "file",
                "activeRevision": {"claimedSize": 4}}],
}


class FakeResult(object):
    def __init__(self, out):
        self.returncode, self.stdout, self.stderr = 0, out, ""


def with_listing(listing, fn, *args):
    real = pd.run_cli
    pd.run_cli = lambda argv, timeout: FakeResult(json.dumps(listing.get(argv[-1], [])))
    try:
        return fn(*args)
    finally:
        pd.run_cli = real


files, dirs = with_listing(LISTING, S.scan_remote, "/r", [])
check("the scan drops every unusable name and keeps the rest",
      (sorted(files), sorted(dirs)), (["notes.txt", "sub/deep.txt"], ["sub"]))

# A recursive transfer is carried out by the CLI, which would write the very
# name the scan refused — so a folder holding one is never transferred whole.
TAINTED = {
    "/r": [{"name": {"ok": True, "value": "good"}, "type": "folder"},
           {"name": {"ok": True, "value": "bad"}, "type": "folder"}],
    "/r/good": [{"name": {"ok": True, "value": "f.txt"}, "type": "file",
                 "activeRevision": {"claimedSize": 1}}],
    "/r/bad": [{"name": {"ok": True, "value": "../escape.txt"}, "type": "file"},
               {"name": {"ok": True, "value": "g.txt"}, "type": "file",
                "activeRevision": {"claimedSize": 1}}],
}
tainted_files, tainted_dirs = with_listing(TAINTED, S.scan_remote, "/r", [])
check("the folder that held a refused name is marked",
      (tainted_dirs["bad"].get("tainted"), tainted_dirs["good"].get("tainted")),
      (True, None))

tplan = S.plan_actions(tainted_files, tainted_dirs, {}, {},
                       {"files": {}, "dirs": set()}, True, None)
check("a marked folder is made directly and its files fetched one by one",
      (sorted(tplan["download_dirs"]), sorted(tplan["mkdir_local"]),
       sorted(tplan["download"])),
      (["good"], ["bad"], ["bad/g.txt"]))

# A path whose own leaf cannot be saved is refused before the CLI is asked.
check("the panel refuses to download a node that cannot be named locally",
      pd.safe_name(pd.leaf_name("/my-files/..\\/escape.txt")), False)

# A folder pretending to be a filesystem of its own is stopped, not followed.
DEEP = {"/r": [{"name": {"ok": True, "value": "a"}, "type": "folder"}]}
DEEP.update({"/r" + "/a" * n: [{"name": {"ok": True, "value": "a"}, "type": "folder"}]
             for n in range(1, S.MAX_REMOTE_DEPTH + 3)})
check("refuses a remote tree deeper than the limit",
      with_listing(DEEP, raises, S.scan_remote, "/r", []), True)

# --- display strings -------------------------------------------------------
#
# A name reaches a notification and the panel. It may not carry markup, fake a
# second line, or run to any length it likes.

check("scrubs control characters out of display text",
      pd.clean_text("two\nlines\tand\x00a null"), "two lines and a null")
check("caps display text", len(pd.clean_text("x" * 999)), 200)
check("escapes markup for a notification body",
      pd.notify_text("<b>Invoice</b> & co"), "&lt;b&gt;Invoice&lt;/b&gt; &amp; co")
check("but leaves a summary alone, which is plain by specification",
      pd.clean_text("A & B"), "A & B")
check("a listed name is scrubbed but its path is not",
      pd.normalize_node({"name": {"ok": True, "value": "we\nird"}, "type": "file"}, "/p"),
      {"name": "we ird", "type": "file", "path": "/p/we\nird", "size": None,
       "time": "", "shared": False, "local": ""})
check("a drag-out path is only offered for a usable name",
      (pd.local_copy("../../.bashrc", os.path.expanduser("~")),
       pd.local_copy("..", os.path.expanduser("~"))),
      ("", ""))

# --- the download folder is a setting, and settings are typed by hand -------

real_env = os.environ.get("OMARCHY_PROTON_DRIVE_DIR")
try:
    os.environ["OMARCHY_PROTON_DRIVE_DIR"] = "/tmp/two\nlines"
    check("an unusable download folder falls back to the default",
          pd.take_dest(["/my-files/x"])[0], pd.default_dest())
    os.environ["OMARCHY_PROTON_DRIVE_DIR"] = "/tmp/fine"
    check("a usable one is honoured", pd.take_dest(["/my-files/x"])[0], "/tmp/fine")
finally:
    if real_env is None:
        os.environ.pop("OMARCHY_PROTON_DRIVE_DIR", None)
    else:
        os.environ["OMARCHY_PROTON_DRIVE_DIR"] = real_env

# --- the service unit ------------------------------------------------------

check("quotes a path containing a space",
      S.unit_exec_start("/home/x/my plugins/sync"), '"/home/x/my plugins/sync" watch')
check("leaves an ordinary path unquoted",
      S.unit_exec_start("/home/x/plugin/sync"), "/home/x/plugin/sync watch")
for bad in ('/home/x/wat"ch', "/home/x/%n/sync", "/home/x/a;b/sync",
            "/home/x/back\\slash/sync", "relative/sync", "/home/x/two\nlines"):
    check("refuses to write a unit for %r" % bad, S.unit_exec_start(bad), "")

check("the unit names the watcher exactly once",
      (S.UNIT_TEXT % S.unit_exec_start("/home/x/plugin/sync")).count(" watch"), 1)

# --- pairs are re-checked before they move anything ------------------------

for pair in ({"remote": "relative", "local": "/tmp/x"},
             {"remote": "/", "local": "/tmp/x"},
             {"remote": "/trash/x", "local": "/tmp/x"},
             {"remote": "/my-files", "local": "/tmp/x"},
             {"remote": "/my-files/Docs", "local": "relative"},
             {"remote": "/my-files/Docs", "local": ""}):
    check("refuses to run the pair %r" % pair, raises(S.run_pair, pair), True)

# --- the execution half, with a CLI that does as it is told -----------------
#
# The planner tests stop at the decision. This one carries a plan out against a
# stubbed CLI, because the containment rules only matter if they hold on the
# path that actually writes to disk.

PAIR_ROOT = tempfile.mkdtemp(prefix="pd-sec-exec-")
try:
    landed = []

    def fake_cli(argv, timeout):
        # "download": write the named file into the destination it was given.
        if argv[:2] == ["filesystem", "download"]:
            target = argv[-1]
            landed.append(target)
            with open(os.path.join(target, "f.txt"), "w") as handle:
                handle.write("x")
            return FakeResult(json.dumps([{"transferredItems": 1}]))
        return FakeResult(json.dumps([{"transferredItems": 0}]))

    remote_files = {"sub/f.txt": {"type": "file", "path": "/r/sub/f.txt",
                                  "size": 1, "mtime": 1000.0, "sha1": ""}}
    plan = {"mkdir_local": ["sub"], "conflicts": [], "upload_dirs": [], "upload": [],
            "download": ["sub/f.txt"], "download_dirs": [], "trash_remote": [],
            "trash_local": [], "touch_local": [], "keep": {}, "unchanged": 0}

    real = pd.run_cli
    pd.run_cli = fake_cli
    try:
        counts, files = S.execute({"remote": "/r", "local": PAIR_ROOT}, plan,
                                  remote_files, {}, {}, {}, lambda *a, **k: None)
    finally:
        pd.run_cli = real

    written = os.path.join(PAIR_ROOT, "sub", "f.txt")
    check("the download lands inside the pair", os.path.isfile(written), True)
    check("it went to the folder the plan named", landed, [os.path.join(PAIR_ROOT, "sub")])
    check("its timestamp is restored, or the next run would bounce it back up",
          os.stat(written).st_mtime, 1000.0)
    check("the run is recorded in the new state", sorted(files), ["sub/f.txt"])
    check("and counted", counts["downloaded"], 1)

    # The same plan with a traversal key stops before anything is written.
    escaped = {"../f.txt": dict(remote_files["sub/f.txt"])}
    bad_plan = dict(plan, mkdir_local=[], download=["../f.txt"])
    pd.run_cli = fake_cli
    try:
        check("a traversal key stops the run instead of writing outside",
              raises(S.execute, {"remote": "/r", "local": PAIR_ROOT}, bad_plan,
                     escaped, {}, {}, {}, lambda *a, **k: None), True)
    finally:
        pd.run_cli = real
    check("and nothing escaped while trying",
          os.path.exists(os.path.join(os.path.dirname(PAIR_ROOT), "f.txt")), False)
finally:
    shutil.rmtree(PAIR_ROOT, ignore_errors=True)

# --- a folder name is data, not a flag -------------------------------------
#
# `sync` is reachable over the shell's IPC socket, so its argument is as
# untrusted as anything off the drive: it must not be able to spell itself
# "--force" and switch off the guard that refuses mass deletions.

captured = {}


def fake_run(argv):
    real_load, real_emit = S.load_config, S.pd.emit
    S.load_config = lambda: {"pairs": []}
    S.pd.emit = lambda payload: captured.update(payload)
    try:
        S.cmd_run(argv)
    finally:
        S.load_config, S.pd.emit = real_load, real_emit
    return captured


check("a folder called --force is looked up, not obeyed",
      "--force is not being synced" in str(fake_run(["--", "--force"]).get("error")), True)
check("an ordinary flag still works",
      fake_run(["--force"]).get("error"), "No folders are set up to sync yet")

# --- state files are private ----------------------------------------------

STATE = tempfile.mkdtemp(prefix="pd-sec-state-")
try:
    target = os.path.join(STATE, "nested", "state.json")
    S.write_json(target, {"files": {"secret-document.pdf": {}}})
    check("state files are readable only by their owner",
          oct(os.stat(target).st_mode & 0o777), oct(0o600))
    check("the state directory is private too",
          oct(os.stat(os.path.dirname(target)).st_mode & 0o777), oct(0o700))
finally:
    shutil.rmtree(STATE, ignore_errors=True)

print()
if FAILED:
    print("%d FAILED:" % len(FAILED))
    for item in FAILED:
        print("  " + item)
    sys.exit(1)
print("all security tests passed")
