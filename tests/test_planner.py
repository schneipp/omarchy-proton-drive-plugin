#!/usr/bin/env python3
"""Tests for the sync planner — the half of this plugin that can destroy data.

Everything here is a pure function over plain dicts, so the decisions a sync
makes (what to transfer, and above all what to delete) can be checked without a
network, a Proton account, or a single byte moving anywhere.

    python3 tests/test_planner.py
"""

import importlib.machinery
import importlib.util
import json
import os
import sys

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      os.pardir, "bin", "omarchy-proton-drive-sync")
S = importlib.util.module_from_spec(
    importlib.util.spec_from_loader("syncmod",
                                    importlib.machinery.SourceFileLoader("syncmod", HELPER)))
S.__spec__.loader.exec_module(S)

FAILED = []


def check(label, got, want):
    if got != want:
        FAILED.append("%s\n    got:  %r\n    want: %r" % (label, got, want))
        print("FAIL %s" % label)
    else:
        print("ok   %s" % label)


def rfile(size=10, mtime=1000.0, sha1="aaa", path="/r/x"):
    return {"type": "file", "path": path, "size": size, "mtime": mtime, "sha1": sha1}


def lfile(size=10, mtime=1000.0, path="/l/x"):
    return {"type": "file", "path": path, "size": size, "mtime": mtime}


def rdir(name):
    return {"type": "dir", "path": "/r/" + name}


def ldir(name):
    return {"type": "dir", "path": "/l/" + name}


def rec(size=10, mtime=1000.0, rmtime=1000.0, sha1="aaa"):
    return {"size": size, "mtime": mtime, "rmtime": rmtime, "sha1": sha1}


def st(files=None, dirs=None):
    return {"files": files or {}, "dirs": set(dirs or [])}


def never(path):
    raise AssertionError("hashed %s when the answer was already known" % path)


def plan(remote_files=None, remote_dirs=None, local_files=None, local_dirs=None,
         state=None, deletes=True, hasher=never):
    return S.plan_actions(remote_files or {}, remote_dirs or {},
                          local_files or {}, local_dirs or {},
                          state or st(), deletes, hasher)


# --- a first sync ---------------------------------------------------------

p = plan(remote_files={"a.txt": rfile()})
check("new remote file downloads", (p["download"], p["upload"]), (["a.txt"], []))

p = plan(local_files={"a.txt": lfile()})
check("new local file uploads", (p["upload"], p["download"]), (["a.txt"], []))

p = plan(remote_files={"a.txt": rfile()}, local_files={"a.txt": lfile()})
check("identical file is left alone",
      (p["download"], p["upload"], p["unchanged"]), ([], [], 1))

p = plan(remote_files={"a.txt": rfile(mtime=1000.0, sha1="deadbeef")},
         local_files={"a.txt": lfile(mtime=5000.0)},
         hasher=lambda path: "deadbeef")
check("same bytes, drifted stamp -> realign the clock, transfer nothing",
      (p["download"], p["upload"], p["touch_local"]), ([], [], ["a.txt"]))

p = plan(remote_files={"a.txt": rfile(mtime=9000.0, sha1="dead")},
         local_files={"a.txt": lfile(mtime=1000.0)},
         hasher=lambda path: "beef")
check("differing bytes, no history, remote newer -> set local aside, then pull",
      (p["conflicts"], p["download"]), (["a.txt"], ["a.txt"]))

p = plan(remote_files={"a.txt": rfile(mtime=1000.0, sha1="dead")},
         local_files={"a.txt": lfile(mtime=9000.0)},
         hasher=lambda path: "beef")
check("differing bytes, no history, local newer -> push (old revision kept)",
      (p["conflicts"], p["upload"]), ([], ["a.txt"]))

# --- edits on one side ----------------------------------------------------

p = plan(remote_files={"a.txt": rfile(size=20, mtime=2000.0, sha1="new")},
         local_files={"a.txt": lfile(size=10, mtime=1000.0)},
         state=st({"a.txt": rec()}))
check("remote-only edit downloads", (p["download"], p["conflicts"]), (["a.txt"], []))

p = plan(remote_files={"a.txt": rfile()},
         local_files={"a.txt": lfile(size=20, mtime=2000.0)},
         state=st({"a.txt": rec()}))
check("local-only edit uploads", (p["upload"], p["conflicts"]), (["a.txt"], []))

p = plan(remote_files={"a.txt": rfile(size=20, mtime=3000.0, sha1="new")},
         local_files={"a.txt": lfile(size=30, mtime=2000.0)},
         state=st({"a.txt": rec()}))
check("both edited, remote newer -> conflict copy, then download",
      (p["conflicts"], p["download"], p["upload"]), (["a.txt"], ["a.txt"], []))

p = plan(remote_files={"a.txt": rfile(size=20, mtime=2000.0, sha1="new")},
         local_files={"a.txt": lfile(size=30, mtime=3000.0)},
         state=st({"a.txt": rec()}))
check("both edited, local newer -> upload, nothing set aside",
      (p["conflicts"], p["upload"], p["download"]), ([], ["a.txt"], []))

# --- deletions ------------------------------------------------------------

p = plan(remote_files={"a.txt": rfile()}, state=st({"a.txt": rec()}))
check("gone locally and previously tracked -> trash it remotely",
      (p["trash_remote"], p["download"]), (["a.txt"], []))

p = plan(local_files={"a.txt": lfile()}, state=st({"a.txt": rec()}))
check("gone remotely and previously tracked -> trash it locally",
      (p["trash_local"], p["upload"]), (["a.txt"], []))

p = plan(remote_files={"a.txt": rfile()}, state=st({"a.txt": rec()}), deletes=False)
check("deletes off -> the file comes back instead of being removed",
      (p["trash_remote"], p["download"]), ([], ["a.txt"]))

p = plan(local_files={"a.txt": lfile()}, state=st({"a.txt": rec()}), deletes=False)
check("deletes off -> the local file is re-uploaded",
      (p["trash_local"], p["upload"]), ([], ["a.txt"]))

p = plan(remote_files={"a.txt": rfile()}, state=st({"other.txt": rec()}))
check("an untracked file missing on the far side is an addition, not a deletion",
      (p["trash_remote"], p["download"]), ([], ["a.txt"]))

# --- whole subtrees -------------------------------------------------------

p = plan(remote_dirs={"sub": rdir("sub")},
         remote_files={"sub/a.txt": rfile(), "sub/b.txt": rfile()})
check("a brand new remote folder moves as one subtree",
      (p["download_dirs"], p["download"]), (["sub"], []))

p = plan(local_dirs={"sub": ldir("sub")},
         local_files={"sub/a.txt": lfile(), "sub/b.txt": lfile()})
check("a brand new local folder moves as one subtree",
      (p["upload_dirs"], p["upload"]), (["sub"], []))

p = plan(remote_dirs={"sub": rdir("sub")}, remote_files={})
check("an EMPTY new remote folder is just created, not transferred",
      (p["mkdir_local"], p["download_dirs"]), (["sub"], []))

p = plan(remote_dirs={"a": rdir("a"), "a/empty": rdir("a/empty")},
         remote_files={"a/x.txt": rfile()})
check("an empty folder inside a new subtree rides along with it",
      (p["mkdir_local"], p["download_dirs"]), ([], ["a"]))

p = plan(remote_dirs={"sub": rdir("sub")}, remote_files={"sub/a.txt": rfile()},
         state=st({"sub/a.txt": rec()}, ["sub"]))
check("folder deleted locally -> trashed remotely once, not per file",
      (p["trash_remote"], p["download"], p["download_dirs"]), (["sub"], [], []))

p = plan(local_dirs={"sub": ldir("sub")}, local_files={"sub/a.txt": lfile()},
         state=st({"sub/a.txt": rec()}, ["sub"]))
check("folder deleted remotely -> trashed locally once, not per file",
      (p["trash_local"], p["upload"], p["upload_dirs"]), (["sub"], [], []))

p = plan(remote_dirs={"a": rdir("a"), "a/b": rdir("a/b")},
         remote_files={"a/b/c.txt": rfile()})
check("nested new folders collapse to the shallowest transfer",
      (p["download_dirs"], p["download"]), (["a"], []))

p = plan(remote_dirs={"sub": rdir("sub")}, local_dirs={"sub": ldir("sub")},
         remote_files={"sub/a.txt": rfile()})
check("a folder on both sides transfers only its differing contents",
      (p["download_dirs"], p["download"]), ([], ["sub/a.txt"]))

# --- the guard against mass deletion --------------------------------------

check("quiet when nothing is being deleted",
      S.deletion_guard({"trash_remote": [], "trash_local": []}, {}, {}, 100), "")

many = {"f%d.txt" % i: rfile() for i in range(100)}
check("blocks a wholesale deletion",
      S.deletion_guard({"trash_remote": list(many), "trash_local": []}, many, {}, 100) != "",
      True)

few = {"f%d.txt" % i: rfile() for i in range(3)}
check("allows an ordinary handful",
      S.deletion_guard({"trash_remote": list(few), "trash_local": []}, few, {}, 100), "")

three = {"f%d.txt" % i: rfile() for i in range(3)}
check("blocks a small pair losing every file at once (the unmounted drive)",
      S.deletion_guard({"trash_remote": list(three), "trash_local": []}, three, {}, 3) != "",
      True)

two = {"f%d.txt" % i: rfile() for i in range(2)}
check("still lets a two-file folder be emptied on purpose",
      S.deletion_guard({"trash_remote": list(two), "trash_local": []}, two, {}, 2), "")

check("counts deletions on both sides together",
      S.deletion_guard({"trash_remote": ["a.txt"], "trash_local": ["b.txt", "c.txt"]},
                       {"a.txt": rfile()}, {"b.txt": lfile(), "c.txt": lfile()}, 3) != "",
      True)

tree = {"sub/f%d.txt" % i: rfile() for i in range(40)}
check("expands a folder to its contents rather than counting it as one",
      S.deletion_guard({"trash_remote": ["sub"], "trash_local": []}, tree, {}, 40) != "", True)

# --- comparison helpers ---------------------------------------------------

check("equal size and stamp needs no hash", S.same_content(rfile(), lfile(), never), True)
check("differing size is settled without a hash",
      S.same_content(rfile(size=1), lfile(size=2), never), False)
check("no remote digest and a differing stamp counts as changed",
      S.same_content(rfile(mtime=1.0, sha1=""), lfile(mtime=900.0), never), False)
check("a digest outranks the timestamp",
      S.remote_matches_state(rfile(mtime=99999.0), rec()), True)
check("a differing digest is a change",
      S.remote_matches_state(rfile(sha1="zzz"), rec()), False)
check("local match needs both size and stamp",
      (S.local_matches_state(lfile(), rec()),
       S.local_matches_state(lfile(mtime=2000.0), rec())), (True, False))
check("expand_rels gathers a subtree",
      sorted(S.expand_rels(["sub"], {"sub/a": 1, "sub/deep/b": 1, "other": 1})),
      ["sub/a", "sub/deep/b"])
check("expand_rels ignores a name that merely shares a prefix",
      S.expand_rels(["sub"], {"subtle": 1}), [])

# --- refusing a dangerous pairing -----------------------------------------

cfg = {"pairs": [{"remote": "/my-files/A", "local": os.path.expanduser("~/Sync/A")}]}
check("rejects a folder already synced",
      S.validate_local(os.path.expanduser("~/Sync/A"), cfg) != "", True)
check("rejects a folder nested inside a synced one",
      S.validate_local(os.path.expanduser("~/Sync/A/inner"), cfg) != "", True)
check("rejects a folder containing a synced one",
      S.validate_local(os.path.expanduser("~/Sync"), cfg) != "", True)
check("rejects home itself", S.validate_local(os.path.expanduser("~"), cfg) != "", True)
check("rejects the download folder", S.validate_local(S.pd.resolve_dest(""), cfg) != "", True)
check("accepts an unrelated folder", S.validate_local(os.path.expanduser("~/Sync/B"), cfg), "")
check("rejects the drive root", S.syncable_remote("/") != "", True)
check("rejects a section root", S.syncable_remote("/my-files") != "", True)
check("rejects trash", S.syncable_remote("/trash/x") != "", True)
check("accepts a real folder", S.syncable_remote("/my-files/Docs"), "")

# --- remote names are hostile input ---------------------------------------
#
# A node name comes from whoever owns or shared the folder, so it has to be
# treated like any other untrusted string before it becomes a local path.

for bad in ("..", ".", "", "../outside.txt", "a/b", "/etc/passwd", "x\0y"):
    check("rejects the remote name %r" % bad, S.pd.safe_name(bad), False)
for good in ("notes.txt", "..hidden", "a..b", "Ordner mit Leerzeichen", "-", "..."):
    check("accepts the remote name %r" % good, S.pd.safe_name(good), True)

root = os.path.join(os.sep, "tmp", "pair")
check("maps a plain key under the pair root",
      S.local_path(root, "sub/file.txt"), os.path.join(root, "sub", "file.txt"))
check("an empty key is the root itself", S.local_path(root, ""), root)


def escapes(rel):
    try:
        S.local_path(root, rel)
    except RuntimeError:
        return True
    return False


for bad in ("../outside.txt", "sub/../../outside.txt", "..", "/etc/passwd", "sub//../.."):
    check("refuses to build a local path from %r" % bad, escapes(bad), True)

# A listing straight out of the CLI, with a traversal attempt in it. The scan
# has to drop that entry — and the folder's whole subtree with it — before the
# planner ever sees a key it would happily download.
LISTING = {
    "/r": [{"name": {"ok": True, "value": ".."}, "type": "folder"},
           {"name": {"ok": True, "value": "../evil.txt"}, "type": "file"},
           {"name": {"ok": True, "value": "notes.txt"}, "type": "file",
            "activeRevision": {"claimedSize": 3}},
           {"name": {"ok": True, "value": "sub"}, "type": "folder"}],
    "/r/sub": [{"name": {"ok": True, "value": "deep.txt"}, "type": "file",
                "activeRevision": {"claimedSize": 4}}],
}


class FakeResult(object):
    def __init__(self, out):
        self.returncode, self.stdout, self.stderr = 0, out, ""


real_run_cli = S.pd.run_cli
S.pd.run_cli = lambda args, timeout: FakeResult(json.dumps(LISTING.get(args[-1], [])))
try:
    scanned_files, scanned_dirs = S.scan_remote("/r", [])
finally:
    S.pd.run_cli = real_run_cli

check("the scan drops traversal names and keeps the rest",
      (sorted(scanned_files), sorted(scanned_dirs)),
      (["notes.txt", "sub/deep.txt"], ["sub"]))

check("a drag-out path is only offered for a safe name",
      (S.pd.local_copy("../../.bashrc", os.path.expanduser("~/Downloads")),
       S.pd.local_copy("..", os.path.expanduser("~/Downloads"))),
      ("", ""))

print()
if FAILED:
    print("%d FAILED:" % len(FAILED))
    for item in FAILED:
        print("  " + item)
    sys.exit(1)
print("all planner tests passed")
