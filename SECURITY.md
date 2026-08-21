# Security

This plugin moves files between someone's computer and their Proton Drive. Two
things follow from that, and everything below is a consequence of them:

1. **A folder's contents are not trustworthy input.** Node names, sizes and
   timestamps come from whoever owns or shared that folder. A shared folder is
   another person's data entirely.
2. **The dangerous verbs are local.** Writing, overwriting and deleting happen
   on the user's disk, so that is where the limits have to hold.

## Trust boundaries

| Source | Trusted? | Where it is checked |
| --- | --- | --- |
| Remote listings (`filesystem list --json`) | **No** | `scan_remote()`, `normalize_node()` |
| Remote node names | **No** | `pd.safe_name()`, `local_path()` |
| Paths over the shell IPC (`browse`, `sync`, `upload`) | **No** | `pd.safe_remote_path()`, `pd.safe_local_path()`, `cmd_run()` |
| Dropped `text/uri-list` payloads | **No** | `Model.localPathsFromUrls()`, `cmd_upload()` |
| `~/.config/omarchy-proton-drive/sync.json` | **No** — a plain file anything can edit | `run_pair()` re-validates every pair |
| Widget settings (`startPath`, `downloadDir`) | Semi — the user's own, but unvalidated text | `cmd_list()`, `take_dest()` |
| The Proton Drive CLI binary | Yes — it is the thing being wrapped | — |

## What is enforced, and where

**A remote name is one path component or it is nothing.** `pd.safe_name()`
rejects `""`, `.`, `..`, anything containing `/`, a NUL or a control character,
and anything over 255 bytes. `scan_remote()` drops such a node whole — a folder
takes its entire subtree with it — so a name like `../outside.txt` never becomes
a key the planner would act on. This was
[reported by @ryanrhughes](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/917)
and is the reason the rest of this document exists.

**Every local path is proved to be inside the pair.** `local_path()` rebuilds
each path from its sync key and refuses anything that does not resolve under the
paired folder — twice: once on the literal path, once on the fully resolved one,
so a symlink cannot walk out either. The pair root may itself be a symlink; that
is how an external disk is usually reached.

**A recursive transfer is never asked for over a refused name.** A folder
download is carried out by the CLI in one recursive call, which would write the
very name the scan refused — so `scan_remote()` marks the folder holding one,
and the planner makes that folder directly and fetches its files individually
instead. The panel's own download refuses a node whose leaf cannot be a local
file name at all.

**A download folder is only used if it is a path.** It comes from a widget
setting or an environment variable; if it is not a plain absolute path, the
built-in default is used rather than handed on.

**Nothing odd reaches another program's argv.** No `shell=True`, no
`os.system()`, no string-built commands anywhere in the plugin — every call is an
argument list. On top of that, `pd.run_cli()` refuses any argument that is not a
string or that carries a NUL or a newline, remote paths must start with `/`
(so a name beginning with `-` can never arrive as an option), and `--` separates
flags from folder names in `run` and from the watched directory for
`inotifywait`.

**A name cannot style, lengthen or fake a message.** `pd.clean_text()` strips
control characters and caps length. A notification body is markup to every
daemon that shows it, so `pd.notify_text()` escapes it there — and only there,
since the summary is plain by specification. In the panel, every label carries
`textFormat: Text.PlainText`; Qt's default would render a file called
`<img src=…>` as rich text and fetch the image. Text handed to shared components
whose renderer is not ours to set (tooltips render as `AutoText`) goes through
`Model.plain()`, which replaces angle brackets rather than escaping them —
entities would show up literally in a string Qt decides is plain.

**A hostile folder cannot exhaust the machine.** The remote scan stops at 64
levels of nesting and 200 000 nodes, and listings shown in the panel are capped
at 400 entries.

**The state files are private.** They inventory every file name in a synced
folder along with its content hash, so the state directory is created `0700` and
the files `0600`, opened with `O_NOFOLLOW`, and written atomically.

**Deletions are guarded.** A run that would delete more than half of the tracked
files, or all of them, refuses and says so; `--force` is required to proceed. A
missing local folder is treated as an unmounted disk, not as "everything was
deleted". Nothing is ever hard-deleted: remote goes to the Proton trash, local to
the XDG trash. `sync` over IPC cannot pass `--force`, because folder names are
read after a `--`.

**The service unit is generated, so it is generated carefully.**
`unit_exec_start()` quotes a path containing a space and refuses outright to
write a unit for a path containing `"`, `\`, `%`, `;` or a newline rather than
guessing at an escape. The unit runs with `NoNewPrivileges=yes`,
`RestrictSUIDSGID=yes`, `LockPersonality=yes` and `PrivateTmp=yes`.

## What this plugin never does

- No network of its own. Every byte moves through the `proton-drive` CLI.
- No credential handling. Sign-in happens in that CLI and a browser; the plugin
  never sees, stores or forwards a password, token or key.
- No telemetry, no analytics, no phoning home. Nothing is sent anywhere the user
  did not point it at.
- No privilege escalation. No `sudo`, no system units, no writes outside
  `~/.config`, `~/.local/state`, the download folder and the paired folders.
- No shell interpretation and no `eval` in any language used here.
- No writing outside a pair. The only paths the sync engine creates or removes
  are ones `local_path()` has proved to be inside the folder the user chose.

## Capabilities, and why each one is needed

The marketplace's automated baseline flags this plugin for *service management*.
That is accurate and expected:

| Capability | Why | Where |
| --- | --- | --- |
| `systemctl --user` | Folder sync must keep running while the bar restarts, so the watcher is a user unit rather than a thread in the shell. Only this plugin's own unit is ever touched. | `ensure_unit()`, `set_daemon()`, `daemon_active()` |
| `notify-send` | Transfer results the user would otherwise never see. | `pd.notify()` |
| `zenity` | Choosing a local folder to pair — the panel has no text input. | `cmd_pick()` |
| `xdg-open` | "Open the download folder". | `cmd_open()` |
| `inotifywait` | Noticing local edits without polling a large tree. | `watch()` |
| `omarchy-launch-tui` | `auth login` needs a terminal that stays alive until sign-in finishes. | `cmd_login()` |

## Limits worth being honest about

- The `proton-drive` CLI is a ~120 MB bundled binary from a third party. This
  plugin wraps it; it cannot vouch for it.
- Sizes, hashes and timestamps are what the drive reports. A hostile server
  could misreport them and cause needless transfers or a wrong conflict call. It
  could not use them to write outside a paired folder — that is the property
  `local_path()` enforces regardless of any metadata.
- Anything that can already run as the user can edit the config file, the state
  files or these scripts. The re-validation in `run_pair()` is defence in depth
  against a stale or mangled config, not a claim to survive a compromised
  account.
- Recursive folder downloads still trust the CLI to keep the names it writes
  inside the destination it was given. That trust is bounded: the sync engine
  never asks for one over a folder that held a refused name, and the panel
  refuses a node whose own name could not be a local file.
- A file whose name contains a control character, a `/`, or that is 256 bytes or
  longer is skipped rather than synced. That is a deliberate trade: such a name
  cannot be represented safely as a local path component, and skipping it is
  visible in the daemon log.

## Tests

```bash
tests/run
```

`tests/test_security.py` is the hostile-input half: traversal names, symlinks
pointing out of a pair, control characters, oversized names, argument injection,
markup in notifications, unit-file injection, flag smuggling over IPC, and state
file permissions. It touches no network, no Proton account and no file outside a
temporary directory it removes afterwards.

## Reporting a vulnerability

Open a [GitHub issue](https://github.com/schneipp/omarchy-proton-drive-plugin/issues)
for anything non-sensitive, or use GitHub's private vulnerability reporting on
the same repository if a public issue would put users at risk. A report that
comes with a way to reproduce it will always be answered.
