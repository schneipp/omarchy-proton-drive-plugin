// Presentation helpers for the Proton Drive panel. Everything about remote
// path arithmetic lives in the `omarchy-proton-drive` helper script; this file
// only turns already-normalised entries into text and glyphs.
//
// Every glyph below was verified by rendering it in JetBrainsMono Nerd Font —
// `fc-list :charset=...` reports false positives, and a missing codepoint
// shows up in the panel as a tofu box.

var IMAGE_EXTENSIONS = {
  jpg: true, jpeg: true, png: true, gif: true, webp: true, avif: true,
  heic: true, heif: true, svg: true, bmp: true, tif: true, tiff: true
}

var VIDEO_EXTENSIONS = {
  mp4: true, mov: true, mkv: true, webm: true, avi: true, m4v: true,
  mpg: true, mpeg: true, wmv: true
}

var AUDIO_EXTENSIONS = {
  mp3: true, flac: true, wav: true, ogg: true, opus: true, m4a: true, aac: true
}

var SHEET_EXTENSIONS = { xls: true, xlsx: true, ods: true, csv: true, numbers: true }
var DOC_EXTENSIONS = { doc: true, docx: true, odt: true, rtf: true, pages: true }
var CODE_EXTENSIONS = {
  js: true, ts: true, py: true, sh: true, rb: true, go: true, rs: true,
  c: true, h: true, cpp: true, json: true, yaml: true, yml: true, toml: true,
  html: true, css: true, qml: true
}

var SECTION_GLYPHS = {
  "/my-files": "\uF015",              // home
  "/devices": "\uF109",               // laptop
  "/shared-with-me": "\uF1E0",        // share
  "/shared-by-me": "\uF1E0",
  "/trash": "\uF1F8",                 // trash can
  "/photos": "\uF03E",                // image
  "/albums": "\uF03E",
  "/photos-shared-by-me": "\uF1E0",
  "/photos-shared-with-me": "\uF1E0",
  "/photos-trash": "\uF1F8"
}

function fileExtension(name) {
  var text = String(name || "")
  var dot = text.lastIndexOf(".")
  if (dot <= 0 || dot === text.length - 1) return ""
  return text.substring(dot + 1).toLowerCase()
}

function entryGlyph(entry) {
  if (!entry) return "\uF15B"
  if (entry.type === "section") return SECTION_GLYPHS[String(entry.path)] || "\uF07B"
  if (entry.type === "folder" || entry.type === "album") return "\uF07B"   // folder
  if (entry.type === "photo") return "\uF03E"                             // image

  var ext = fileExtension(entry.name)
  if (IMAGE_EXTENSIONS[ext]) return "\uF03E"
  if (VIDEO_EXTENSIONS[ext]) return "\uF03D"    // film
  if (AUDIO_EXTENSIONS[ext]) return "\uF001"    // music
  if (ext === "pdf") return "\uF1C1"
  if (SHEET_EXTENSIONS[ext]) return "\uF1C3"
  if (DOC_EXTENSIONS[ext]) return "\uF1C2"
  if (CODE_EXTENSIONS[ext]) return "\uF121"     // </>
  return "\uF15B"                               // generic file
}

function formatBytes(bytes) {
  var value = Number(bytes)
  if (!isFinite(value) || value <= 0) return ""
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function relativeTime(iso, nowMs) {
  var text = String(iso || "")
  if (text === "") return ""
  var stamp = Date.parse(text)
  if (!isFinite(stamp)) return ""
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - stamp) / 1000))
  if (diff < 60) return "just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function entryMeta(entry, nowMs) {
  if (!entry) return ""
  var parts = []
  if (entry.type === "section") return ""
  if (entry.type === "folder" || entry.type === "album") parts.push("Folder")
  var size = formatBytes(entry.size)
  if (size !== "") parts.push(size)
  var when = relativeTime(entry.time, nowMs)
  if (when !== "") parts.push(when)
  if (entry.shared) parts.push("shared")
  // "on disk" is not trivia: only a row with a local copy can be dragged out,
  // because a drag has to hand over a real file:// URI the instant it starts.
  if (entry.local) parts.push("on disk")
  return parts.join(" · ")
}

// file:// URI for the drag payload. Each segment is encoded separately so that
// spaces and "#" survive while the separators stay separators.
function fileUri(path) {
  var parts = String(path || "").split("/")
  for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
  return "file://" + parts.join("/")
}

function baseName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1] || String(path || "")
}

// Local paths out of a dropped text/uri-list payload, skipping anything that
// is not a plain file (http drops, x-special/ URIs, and so on).
function localPathsFromUrls(urls) {
  var paths = []
  if (!urls) return paths
  for (var i = 0; i < urls.length; i++) {
    var url = String(urls[i])
    if (url.indexOf("file://") !== 0) continue
    paths.push(decodeURIComponent(url.substring(7)))
  }
  return paths
}

// --- sync ------------------------------------------------------------------
//
// A pair is a remote folder tied to a local one. A folder in the listing is
// either paired itself, inside a folder that is paired, or neither — and those
// three cases want three different affordances, so they get named here rather
// than being re-derived at each call site.

function findPair(pairs, path) {
  var target = String(path || "")
  for (var i = 0; i < (pairs || []).length; i++) {
    if (String(pairs[i].remote) === target) return pairs[i]
  }
  return null
}

function coveringPair(pairs, path) {
  var target = String(path || "")
  for (var i = 0; i < (pairs || []).length; i++) {
    var remote = String(pairs[i].remote)
    if (target.indexOf(remote + "/") === 0) return pairs[i]
  }
  return null
}

// "none" | "self" | "covered" — a folder already covered by an ancestor pair
// must not offer to be paired again, or the two would sync the same bytes.
function syncStateFor(pairs, path) {
  var own = findPair(pairs, path)
  if (own) return { kind: "self", pair: own }
  var parent = coveringPair(pairs, path)
  if (parent) return { kind: "covered", pair: parent }
  return { kind: "none", pair: null }
}

function isBusy(pair) {
  return !!pair && (pair.state === "scanning" || pair.state === "transferring")
}

function progressText(pair) {
  var progress = pair && pair.progress
  if (!progress || !progress.total) return ""
  return progress.done + "/" + progress.total
}

// What one pair is doing right now, in one line.
function pairMeta(pair, nowMs) {
  if (!pair) return ""
  if (pair.state === "scanning") return "Looking for changes…"
  if (pair.state === "transferring") {
    var progress = progressText(pair)
    return String(pair.detail || "Transferring…") + (progress ? " · " + progress : "")
  }
  if (pair.state === "error" || pair.error) return String(pair.error || "Sync failed")
  if (pair.state === "paused") return "Paused"

  var parts = []
  var when = relativeTime(pair.lastRun, nowMs)
  parts.push(when === "" ? "not synced yet" : "synced " + when)
  if (pair.files) parts.push(pair.files + (pair.files === 1 ? " file" : " files"))
  return parts.join(" · ")
}

// What just happened, for the line under the SYNC header. Counts of nothing
// are not worth reporting, so a quiet run says so rather than listing zeros.
function lastChange(pair) {
  var summary = pair && pair.summary
  if (!summary) return ""
  var parts = []
  if (summary.downloaded) parts.push(summary.downloaded + " in")
  if (summary.uploaded) parts.push(summary.uploaded + " out")
  if (summary.deletedRemote) parts.push(summary.deletedRemote + " removed there")
  if (summary.deletedLocal) parts.push(summary.deletedLocal + " removed here")
  if (summary.conflicts) parts.push(summary.conflicts + " conflict" + (summary.conflicts === 1 ? "" : "s"))
  return parts.join(" · ")
}

function syncHeadline(pairs, daemon, nowMs) {
  var list = pairs || []
  if (list.length === 0) return "Nothing synced yet"

  var newest = ""
  for (var i = 0; i < list.length; i++) {
    if (isBusy(list[i])) {
      var progress = progressText(list[i])
      return "Syncing " + list[i].name + (progress ? " · " + progress : "") + "…"
    }
    if (String(list[i].lastRun || "") > newest) newest = String(list[i].lastRun || "")
  }
  for (var j = 0; j < list.length; j++) {
    if (list[j].state === "error" || list[j].error) {
      return list[j].name + ": " + String(list[j].error || "sync failed")
    }
  }

  var parts = [list.length + (list.length === 1 ? " folder" : " folders")]
  var when = relativeTime(newest, nowMs)
  if (when !== "") parts.push("synced " + when)
  // Worth saying out loud: without the watcher, nothing syncs by itself and
  // the panel would otherwise look perfectly healthy.
  if (!daemon) parts.push("watching off")
  return parts.join(" · ")
}

// Folders are descended into, files are downloaded — the whole interaction
// model of the panel comes down to this one predicate.
function isContainer(entry) {
  if (!entry) return false
  return entry.type === "folder" || entry.type === "section" || entry.type === "album"
}

function parseResponse(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  try {
    return JSON.parse(text)
  } catch (error) {
    return null
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    fileExtension: fileExtension,
    entryGlyph: entryGlyph,
    formatBytes: formatBytes,
    relativeTime: relativeTime,
    entryMeta: entryMeta,
    fileUri: fileUri,
    baseName: baseName,
    localPathsFromUrls: localPathsFromUrls,
    isContainer: isContainer,
    parseResponse: parseResponse,
    findPair: findPair,
    coveringPair: coveringPair,
    syncStateFor: syncStateFor,
    isBusy: isBusy,
    pairMeta: pairMeta,
    lastChange: lastChange,
    syncHeadline: syncHeadline
  }
}
