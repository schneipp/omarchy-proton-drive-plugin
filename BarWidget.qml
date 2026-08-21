import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Proton Drive browser for the bar.
//
// The panel is a file browser, not a status readout: click a folder to descend,
// click a file to download it. Every remote operation goes through
// `bin/omarchy-proton-drive`, a bundled helper that wraps the Proton Drive CLI and
// hands back a stable JSON contract — the CLI is a ~120MB bundled binary whose
// own JSON shape is undocumented, so keeping that normalisation out of QML
// means a CLI change is a one-file fix.
//
// Nothing polls. Each listing costs a process spawn plus a network round-trip
// and a decryption pass, so work happens only when the user opens the panel,
// navigates, or asks for a refresh.
//
// Every label here carries `textFormat: Text.PlainText`, without exception. A
// file name is remote input — it comes from whoever owns or shared the folder
// — and Qt's default AutoText would render one containing markup as rich text,
// which at best fakes the panel's own wording and at worst pulls an <img> off
// the network. Text handed to shared components (tooltips, whose renderer is
// not ours to set) goes through Model.plain() for the same reason.
Panel {
  id: root
  moduleName: "rams.proton-drive"
  ipcTarget: "rams.proton-drive"
  manageIpc: false

  readonly property string startPath: String(setting("startPath", "/my-files") || "/my-files")
  readonly property string downloadDir: String(setting("downloadDir", "") || "")

  // Both helpers ship inside the plugin rather than on PATH, so installing it is
  // nothing more than cloning the repo — `omarchy plugin add` does the whole job.
  // Resolved from this file's own URL because the directory is named after the
  // manifest id, which the user is free to change.
  readonly property string pluginDir: String(Qt.resolvedUrl("bin/")).replace(/^file:\/\//, "")
  readonly property string helper: pluginDir + "omarchy-proton-drive"
  readonly property string syncHelper: pluginDir + "omarchy-proton-drive-sync"

  property string currentPath: ""
  property string requestedPath: ""
  // Handed back with every listing, so QML never has to know that a node name
  // may contain a "/" escaped as "\/".
  property string parentPath: "/"
  property string title: "Proton Drive"
  property var entries: []
  property int truncated: 0

  property bool installed: true
  property bool authenticated: false
  property bool loading: false
  property string errorText: ""
  property string notice: ""

  // Drag and drop. `dropHover` is a drag from another app sitting over us,
  // `dragActive` is one of our own rows on its way out.
  property bool uploading: false
  property bool dropHover: false
  property bool dragActive: false

  // Remote path of the download in flight, "" when idle. Only one at a time:
  // the panel is a browser, not a download manager, and serialising keeps the
  // status line honest.
  property string busyPath: ""

  // Sync. `syncPairs` is the whole picture: every configured pair plus what it
  // is doing right now, read from a status file rather than the network, so
  // watching a sync costs nothing.
  property var syncPairs: []
  property bool syncDaemon: false
  property bool syncExpanded: false
  property bool syncPicking: false
  property string syncBusyRemote: ""

  property int cursorIndex: 0
  property bool cursorActive: false
  property double nowMs: Date.now()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool atRoot: currentPath === "/" || currentPath === ""
  readonly property bool downloading: busyPath !== ""
  readonly property var rows: buildRows()

  readonly property bool canUpload: installed && authenticated && isUploadable(currentPath)

  readonly property bool syncBusy: {
    for (var i = 0; i < syncPairs.length; i++) if (Model.isBusy(syncPairs[i])) return true
    return false
  }
  // The folder on screen can be paired unless it already is, sits inside one
  // that is, or is a section root rather than a real folder.
  readonly property var currentSync: Model.syncStateFor(syncPairs, currentPath)
  readonly property bool canSyncCurrent: authenticated && isSyncable(currentPath)
    && currentSync.kind === "none" && !syncPicking
  // Dropping on the bar icon uploads to whatever is on screen, or to the
  // configured start folder when the panel has never been opened.
  readonly property string barDropTarget: isUploadable(currentPath) ? currentPath : startPath

  readonly property string heroMeta: {
    if (!installed) return "CLI not installed"
    if (!authenticated) return "Not signed in"
    if (uploading) return "Uploading…"
    if (dropHover) return "Drop to upload"
    if (downloading) return "Downloading…"
    if (loading) return "Loading…"
    return title
  }

  // Glyphs verified by rendering them in JetBrainsMono Nerd Font — a missing
  // codepoint renders as a tofu box rather than failing loudly.
  // U+F0C2 cloud · U+F0ED cloud-download · U+F0EE cloud-upload · U+F071 warning
  readonly property string barGlyph: !installed
    ? "\uF071"
    : (uploading || dropHover ? "\uF0EE" : (downloading ? "\uF0ED" : "\uF0C2"))
  readonly property color barIconColor: authenticated && installed
    ? barForeground
    : Qt.darker(barForeground, 1.55)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- data ----------------------------------------------------------------

  function buildRows() {
    var built = []
    if (authenticated && !atRoot) built.push({ kind: "up" })
    for (var i = 0; i < entries.length; i++) built.push({ kind: "entry", entry: entries[i] })
    return built
  }

  function helperCommand(args) {
    var command = [root.helper].concat(args)
    if (downloadDir !== "") command.push("--dest", downloadDir)
    return command
  }

  function checkStatus() {
    if (statusProc.running) return
    statusProc.command = [root.helper, "status"]
    statusProc.running = true
  }

  function load(path) {
    requestedPath = String(path || "/")
    if (listProc.running) return
    startLoad()
  }

  function startLoad() {
    loading = true
    errorText = ""
    listProc.command = helperCommand(["list", requestedPath])
    listProc.running = true
  }

  function refresh() {
    load(currentPath === "" ? startPath : currentPath)
  }

  function applyList(raw) {
    var parsed = Model.parseResponse(raw)
    loading = false

    if (!parsed) {
      errorText = "Could not read the Proton Drive helper output"
      return
    }
    if (parsed.installed === false) installed = false
    if (parsed.authenticated !== undefined) authenticated = parsed.authenticated === true

    if (!parsed.ok) {
      errorText = String(parsed.error || "Could not list this folder")
      if (parsed.authenticated === false) entries = []
      return
    }

    installed = true
    authenticated = true
    errorText = ""
    currentPath = String(parsed.path || requestedPath)
    parentPath = String(parsed.parent || "/")
    title = String(parsed.title || currentPath)
    entries = parsed.entries || []
    truncated = Number(parsed.truncated || 0)
    nowMs = Date.now()
    cursorIndex = 0
  }

  // --- navigation ----------------------------------------------------------

  function selectedRow() {
    if (cursorIndex < 0 || cursorIndex >= rows.length) return null
    return rows[cursorIndex]
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(rows.length - 1, index))
    scrollCursorIntoView()
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy !== 0) {
      setCursor(cursorIndex + dy)
      return
    }
    if (dx < 0) {
      goUp()
      return
    }
    if (dx > 0) {
      var row = selectedRow()
      if (row && row.kind === "entry" && Model.isContainer(row.entry)) enter(row.entry)
    }
  }

  function activateCursor() {
    if (!authenticated) {
      login()
      return
    }
    var row = selectedRow()
    if (!row) return
    if (row.kind === "up") goUp()
    else if (Model.isContainer(row.entry)) enter(row.entry)
    else download(row.entry)
  }

  function enter(entry) {
    if (!entry || !entry.path) return
    notice = ""
    load(entry.path)
  }

  function goUp() {
    if (!authenticated || atRoot) return
    notice = ""
    load(parentPath)
  }

  function goHome() {
    notice = ""
    load(startPath)
  }

  // --- actions -------------------------------------------------------------

  function download(entry) {
    if (!entry || !entry.path || downloadProc.running) return
    busyPath = String(entry.path)
    notice = "Downloading " + entry.name + "…"
    downloadProc.command = helperCommand(["download", entry.path])
    downloadProc.running = true
  }

  function downloadSelected() {
    var row = selectedRow()
    if (row && row.kind === "entry") download(row.entry)
  }

  function login() {
    if (!installed) return
    notice = "Finish signing in from the terminal window, then press r"
    Quickshell.execDetached([root.helper, "login"])
  }

  function openDownloadFolder() {
    Quickshell.execDetached(helperCommand(["open"]))
  }

  // Sections that cannot take an upload. Everything else is left to the CLI,
  // which reports a read-only share or a missing folder better than a guess.
  function isUploadable(path) {
    var p = String(path || "")
    if (p === "" || p === "/") return false
    if (p.indexOf("/trash") === 0 || p.indexOf("/photos-trash") === 0) return false
    if (p === "/devices" || p === "/shared-with-me" || p === "/shared-by-me") return false
    return true
  }

  // Mirrors syncable_remote() in the helper, so the panel never offers a pair
  // the helper is going to refuse. Section roots are not real folders, and a
  // shared folder may be read-only for us.
  function isSyncable(path) {
    var p = String(path || "")
    if (!isUploadable(p)) return false
    if (["/my-files", "/devices", "/shared-with-me", "/shared-by-me",
         "/photos", "/albums"].indexOf(p) >= 0) return false
    return true
  }

  // --- sync ----------------------------------------------------------------

  function refreshSync() {
    if (syncStatusProc.running) return
    syncStatusProc.command = [root.syncHelper, "status"]
    syncStatusProc.running = true
  }

  function applySync(raw) {
    var parsed = Model.parseResponse(raw)
    if (!parsed || !parsed.ok) return
    syncPairs = parsed.pairs || []
    syncDaemon = parsed.daemon === true
    nowMs = Date.now()
    // Poll only while something is actually moving; the rest of the time the
    // panel is as quiet as the rest of this plugin.
    if (syncBusy) syncPollTimer.start()
    else syncPollTimer.stop()
  }

  // Pairing needs a local folder, and the panel has no text input — so this is
  // the one place the plugin reaches for a GUI file chooser.
  function setupSync(path) {
    if (syncPicking || !isSyncable(path)) return
    syncPicking = true
    errorText = ""
    notice = "Choose a local folder to sync " + Model.baseName(path) + " with…"
    syncActionProc.command = [root.syncHelper, "pick", path]
    syncActionProc.running = true
  }

  function syncNow(remote) {
    if (syncActionProc.running) return
    notice = remote === "" ? "Syncing…" : "Syncing " + Model.baseName(remote) + "…"
    syncBusyRemote = String(remote || "")
    // "--" first: a folder name is data, and must never be read as a flag.
    var args = [root.syncHelper, "run"]
    if (remote !== "") args.push("--", remote)
    syncActionProc.command = args
    syncActionProc.running = true
    syncPollTimer.start()
  }

  function unsync(remote) {
    if (syncActionProc.running) return
    notice = "Stopped syncing " + Model.baseName(remote) + " — the files on both sides are untouched"
    syncActionProc.command = [root.syncHelper, "remove", remote]
    syncActionProc.running = true
  }

  // Clicking the control on a folder means "start syncing this" the first
  // time and "sync it now" every time after.
  function toggleSync(path) {
    var state = Model.syncStateFor(syncPairs, path)
    if (state.kind === "self") syncNow(path)
    else if (state.kind === "none") setupSync(path)
  }

  function syncSelected() {
    var row = selectedRow()
    if (row && row.kind === "entry" && Model.isContainer(row.entry)) toggleSync(row.entry.path)
    else if (canSyncCurrent) setupSync(currentPath)
  }

  function uploadUrls(urls, parent) {
    upload(Model.localPathsFromUrls(urls), parent)
  }

  function upload(paths, parent) {
    if (!paths || paths.length === 0 || uploadProc.running) return
    var target = String(parent || "")
    if (!isUploadable(target)) {
      errorText = "Cannot upload into " + (target === "" ? "this view" : target)
      return
    }
    uploading = true
    errorText = ""
    notice = "Uploading " + (paths.length === 1 ? Model.baseName(paths[0]) : paths.length + " items") + "…"
    // Not helperCommand(): upload takes remote-parent-then-locals, and a
    // trailing --dest would be read as one more file to send.
    uploadProc.command = [root.helper, "upload", target].concat(paths)
    uploadProc.running = true
  }

  // A drag out of the panel has to hand over a file:// URI the moment it
  // starts, and there is no way to stall one while a download runs — so a row
  // without a local copy fetches itself and becomes draggable afterwards.
  function beginDragOut(item, entry) {
    if (dragActive || !item || !entry) return false
    if (!entry.local) {
      if (!downloading) {
        notice = "Fetching " + entry.name + " — drag again once it lands"
        download(entry)
      }
      return false
    }
    dragActive = true
    return true
  }

  // --- scrolling -----------------------------------------------------------

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function () {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (!rowColumn) return
    if (cursorIndex >= 0 && cursorIndex < rowColumn.children.length) {
      scrollItemIntoView(rowColumn.children[cursorIndex])
    }
  }

  // --- lifecycle -----------------------------------------------------------

  Component.onCompleted: checkStatus()

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      if (panelFlick) panelFlick.contentY = 0
      nowMs = Date.now()
      if (currentPath === "") load(startPath)
      else refresh()
      refreshSync()
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    } else {
      // The sync itself belongs to a systemd service, not to this panel, so
      // there is nothing to watch once nobody is looking.
      syncPollTimer.stop()
    }
  }

  onCursorIndexChanged: scrollCursorIntoView()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function login(): string { root.login(); return "ok" }
    function path(): string { return root.currentPath }
    function browse(path: string): string { root.load(path); return "ok" }
    // Newline-separated local paths, uploaded to the folder on screen. Same
    // entry point the drop handlers use, so it is also how the upload path
    // gets exercised without a mouse.
    function upload(paths: string): string {
      var list = String(paths || "").split("\n").filter(function (p) { return p.trim() !== "" })
      root.upload(list, root.barDropTarget)
      return "ok"
    }
    function sync(remote: string): string { root.syncNow(String(remote || "")); return "ok" }
    function syncStatus(): string { root.refreshSync(); return JSON.stringify(root.syncPairs) }
  }

  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function (exitCode) {
      var parsed = Model.parseResponse(statusOut.text)
      if (!parsed) return
      root.installed = parsed.installed !== false
      root.authenticated = parsed.authenticated === true
    }
  }

  Process {
    id: listProc
    running: false
    command: []
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function (exitCode) {
      var text = String(listOut.text || "")
      if (text.trim() === "") {
        root.loading = false
        root.errorText = String(listErr.text || "The Proton Drive helper failed").trim()
        return
      }
      root.applyList(text)
      // A navigation that arrived while this listing was in flight wins.
      if (root.requestedPath !== root.currentPath) root.startLoad()
    }
  }

  Process {
    id: downloadProc
    running: false
    command: []
    stdout: StdioCollector { id: downloadOut; waitForEnd: true }
    stderr: StdioCollector { id: downloadErr; waitForEnd: true }
    onExited: function (exitCode) {
      root.busyPath = ""
      var parsed = Model.parseResponse(downloadOut.text)
      if (parsed && parsed.ok) {
        root.notice = "Saved " + String(parsed.label || "file") + " to " + String(parsed.dest || "")
        // Re-list so the row picks up its local copy and becomes draggable.
        root.refresh()
      } else {
        root.notice = ""
        root.errorText = parsed && parsed.error
          ? String(parsed.error)
          : String(downloadErr.text || "Download failed").trim()
        if (parsed && parsed.authenticated === false) root.authenticated = false
      }
      noticeTimer.restart()
    }
  }

  Process {
    id: uploadProc
    running: false
    command: []
    stdout: StdioCollector { id: uploadOut; waitForEnd: true }
    stderr: StdioCollector { id: uploadErr; waitForEnd: true }
    onExited: function (exitCode) {
      root.uploading = false
      var parsed = Model.parseResponse(uploadOut.text)
      if (parsed && parsed.ok) {
        root.notice = "Uploaded " + String(parsed.label || "file")
        root.refresh()
      } else {
        root.notice = ""
        root.errorText = parsed && parsed.error
          ? String(parsed.error)
          : String(uploadErr.text || "Upload failed").trim()
        if (parsed && parsed.authenticated === false) root.authenticated = false
      }
      noticeTimer.restart()
    }
  }

  Process {
    id: syncStatusProc
    running: false
    command: []
    stdout: StdioCollector { id: syncStatusOut; waitForEnd: true }
    onExited: function (exitCode) { root.applySync(syncStatusOut.text) }
  }

  // pick / run / remove all answer with the same shape, and all of them want
  // the pair list re-read afterwards.
  Process {
    id: syncActionProc
    running: false
    command: []
    stdout: StdioCollector { id: syncActionOut; waitForEnd: true }
    stderr: StdioCollector { id: syncActionErr; waitForEnd: true }
    onExited: function (exitCode) {
      root.syncPicking = false
      root.syncBusyRemote = ""
      var parsed = Model.parseResponse(syncActionOut.text)
      if (parsed && parsed.cancelled) {
        root.notice = ""
      } else if (parsed && parsed.ok) {
        var run = parsed.run
        if (run && run.summary) {
          var change = Model.lastChange({ summary: run.summary })
          root.notice = change === "" ? "Already up to date" : "Synced — " + change
        } else if (parsed.results) {
          var changes = []
          for (var i = 0; i < parsed.results.length; i++) {
            var text = Model.lastChange(parsed.results[i])
            if (text !== "") changes.push(text)
          }
          root.notice = changes.length === 0 ? "Already up to date" : "Synced — " + changes.join(" · ")
        }
      } else {
        root.notice = ""
        root.errorText = parsed && parsed.error
          ? String(parsed.error)
          : String(syncActionErr.text || "Sync failed").trim()
      }
      root.refreshSync()
      // A sync changes what is in the folder on screen and which rows have a
      // local copy, so the listing is no longer trustworthy.
      if (parsed && parsed.ok && !parsed.cancelled) root.refresh()
      noticeTimer.restart()
    }
  }

  Timer {
    id: syncPollTimer
    interval: 1500
    repeat: true
    running: false
    onTriggered: root.refreshSync()
  }

  Timer {
    id: noticeTimer
    interval: 6000
    repeat: false
    onTriggered: root.notice = ""
  }

  // --- bar face ------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    active: root.opened
    tooltipText: root.installed
      ? (root.authenticated ? "Proton Drive" : "Proton Drive — not signed in")
      : "Proton Drive CLI is not installed"

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.MiddleButton) root.openDownloadFolder()
      else root.toggle()
    }
  }

  // Files dropped straight onto the bar icon go to the folder on screen, or to
  // the start folder when the panel was never opened. The bar strip is always
  // mapped, so this works without opening the panel first.
  DropArea {
    anchors.fill: parent
    keys: ["text/uri-list"]
    enabled: root.installed && root.authenticated && !root.dragActive
    onEntered: function (drag) {
      root.dropHover = true
      drag.accept(Qt.CopyAction)
    }
    onExited: root.dropHover = false
    onDropped: function (drop) {
      root.dropHover = false
      root.uploadUrls(drop.urls, root.barDropTarget)
      drop.accept(Qt.CopyAction)
    }
  }

  // --- panel ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    // KeyboardPanel normally claims the whole screen as its input region so
    // that a click anywhere outside dismisses it. That same region would also
    // swallow a drag leaving the panel, leaving nowhere on screen to drop the
    // file — so while a row is on its way out, the region shrinks to the card.
    mask: Region {
      x: root.dragActive ? panel.cardOrigin.x : 0
      y: root.dragActive ? panel.cardOrigin.y : 0
      width: root.dragActive ? panel.contentWidth : panel.screenW
      height: root.dragActive ? panel.contentHeight : panel.screenH
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive && dy !== 0) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      // Guarded on `cursorActive` so the first key after the panel takes
      // keyboard focus only arms the cursor. Without it a stray Space or Enter
      // typed at whatever was focused before would fire a real action —
      // launching the sign-in flow or starting a download.
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "u" || t === "U") root.goUp()
        else if (t === "g" || t === "G") root.goHome()
        else if (t === "d" || t === "D") root.downloadSelected()
        else if (t === "o" || t === "O") root.openDownloadFolder()
        else if (t === "s") root.syncSelected()
        else if (t === "S") root.syncNow("")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Proton Drive"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.authenticated ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\uF0C2"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.notice !== "" || root.errorText !== ""
            width: parent.width
            text: root.errorText !== "" ? root.errorText : root.notice
            color: root.errorText !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          LoginRow {
            visible: !root.authenticated
            width: parent.width
          }

          PanelSeparator {
            visible: root.authenticated
            foreground: root.foreground
          }

          // --- sync ---------------------------------------------------------
          // Sits above the listing because it is about the folder as a whole
          // rather than any one row in it.
          ColumnLayout {
            visible: root.authenticated
            width: parent.width
            spacing: Style.space(4)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: "SYNC"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              SyncButton {
                // U+F0EC two-way arrows
                glyph: "\uF0EC"
                visible: root.canSyncCurrent
                tooltip: "Keep " + Model.plain(root.title) + " in step with a local folder (s)"
                tint: root.foreground
                onActivated: root.setupSync(root.currentPath)
              }

              SyncButton {
                // U+F021 circular arrows, turning while a sync is in flight
                glyph: "\uF021"
                visible: root.syncPairs.length > 0
                spinning: root.syncBusy
                enabled: !root.syncPicking
                tooltip: root.syncBusy ? "Syncing…" : "Sync every folder now (S)"
                tint: root.foreground
                onActivated: root.syncNow("")
              }

              SyncButton {
                // U+F077 chevron-up / U+F078 chevron-down
                glyph: root.syncExpanded ? "\uF077" : "\uF078"
                visible: root.syncPairs.length > 0
                tooltip: root.syncExpanded ? "Hide synced folders" : "Show synced folders"
                tint: root.dim
                onActivated: root.syncExpanded = !root.syncExpanded
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              // With nothing set up yet, say where the button is — at a section
              // root the header one is hidden, and only the per-folder ones show.
              text: root.syncPairs.length > 0
                ? Model.syncHeadline(root.syncPairs, root.syncDaemon, root.nowMs)
                : (root.canSyncCurrent
                  ? "Nothing synced yet — press \uF0EC above to keep this folder on your disk"
                  : "Nothing synced yet — press \uF0EC beside a folder to keep it on your disk")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Column {
              Layout.fillWidth: true
              visible: root.syncExpanded && root.syncPairs.length > 0
              spacing: Style.space(2)

              Repeater {
                model: root.syncPairs
                SyncPairRow {
                  required property var modelData
                  width: parent.width
                  pair: modelData
                }
              }
            }
          }

          PanelSeparator {
            visible: root.authenticated
            foreground: root.foreground
          }

          // Breadcrumb plus the actions that are not tied to a single row.
          RowLayout {
            visible: root.authenticated
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              Layout.fillWidth: true
              text: root.title.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PanelActionButton {
              // U+F015 home
              iconText: "\uF015"
              tooltipText: "Go to " + Model.plain(root.startPath) + " (g)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.goHome()
            }

            PanelActionButton {
              // U+F07C open folder
              iconText: "\uF07C"
              tooltipText: "Open the download folder (o)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.openDownloadFolder()
            }

            PanelActionButton {
              // U+F021 refresh
              iconText: "\uF021"
              tooltipText: "Refresh (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.loading
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.refresh()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.authenticated && root.loading && root.entries.length === 0
            width: parent.width
            text: "Loading…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            visible: root.authenticated && !root.loading && root.rows.length === 0 && root.errorText === ""
            width: parent.width
            text: "This folder is empty."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: rowColumn
            visible: root.authenticated && root.rows.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.rows
              EntryRow {
                required property var modelData
                required property int index
                width: rowColumn.width
                row: modelData
                rowIndex: index
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.truncated > 0
            width: parent.width
            text: root.truncated + " more item(s) not shown"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }

    // Files dragged in from anywhere else land in the folder on screen.
    // DropArea only handles drag events, so it sits above the content without
    // stealing a single click from it.
    DropArea {
      anchors.fill: parent
      keys: ["text/uri-list"]
      enabled: root.canUpload && !root.dragActive
      onEntered: function (drag) {
        root.dropHover = true
        drag.accept(Qt.CopyAction)
      }
      onExited: root.dropHover = false
      onDropped: function (drop) {
        root.dropHover = false
        root.uploadUrls(drop.urls, root.currentPath)
        drop.accept(Qt.CopyAction)
      }
    }

    Rectangle {
      anchors.fill: parent
      visible: root.dropHover && root.canUpload
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      border.color: root.foreground
      border.width: Math.max(1, Style.space(2))
      radius: Style.cornerRadius

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: "Drop to upload to " + root.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }
    }
  }

  // --- row components ------------------------------------------------------

  // The sync affordance. PanelActionButton cannot turn its glyph, and in a
  // panel that otherwise never animates, a spinning icon is the clearest way
  // to say "this is happening right now" without spending a line of text.
  component SyncButton: Rectangle {
    id: syncButton
    property string glyph: "\uF0EC"
    property string tooltip: ""
    property color tint: root.foreground
    property bool spinning: false

    signal activated()

    implicitWidth: Style.space(22)
    implicitHeight: Style.space(22)
    radius: Style.cornerRadius
    color: syncMouse.containsMouse && syncButton.enabled
      ? Qt.rgba(tint.r, tint.g, tint.b, 0.14)
      : "transparent"

    Behavior on color { ColorAnimation { duration: 60 } }

    Text {
      textFormat: Text.PlainText
      id: syncGlyph
      anchors.centerIn: parent
      text: syncButton.glyph
      color: syncButton.enabled ? syncButton.tint : Qt.darker(syncButton.tint, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon

      RotationAnimator on rotation {
        running: syncButton.spinning
        from: 0
        to: 360
        duration: 1600
        loops: Animation.Infinite
        onRunningChanged: if (!running) syncGlyph.rotation = 0
      }
    }

    MouseArea {
      id: syncMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: syncButton.activated()
    }

    PanelToolTip {
      visible: syncButton.tooltip !== "" && syncMouse.containsMouse
      text: syncButton.tooltip
      fontFamily: root.fontFamily
    }
  }

  component SyncPairRow: Rectangle {
    id: pairRow
    property var pair: null

    readonly property bool busy: Model.isBusy(pair)
    readonly property bool broken: !!pair && (pair.state === "error" || !!pair.error)

    implicitHeight: pairContent.implicitHeight + Style.space(8)
    color: "transparent"

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(2)
      spacing: Style.space(8)

      SyncButton {
        // U+F071 warning when the last run failed, U+F0EC otherwise
        glyph: pairRow.broken ? "\uF071" : "\uF0EC"
        spinning: pairRow.busy
        tint: pairRow.broken ? root.urgent : (pairRow.busy ? root.foreground : root.dim)
        tooltip: pairRow.pair ? Model.plain(pairRow.pair.local) : ""
        onActivated: if (pairRow.pair) root.syncNow(pairRow.pair.remote)
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: pairContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          // U+F061 arrow-right, remote on the left because that is the side
          // the user just navigated to.
          text: pairRow.pair
            ? pairRow.pair.name + "  \uF061  " + pairRow.pair.localShort
            : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.pairMeta(pairRow.pair, root.nowMs)
          color: pairRow.broken ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        // U+F127 broken link. Destructive-looking, but only to the pairing:
        // both copies of the files stay exactly where they are.
        iconText: "\uF127"
        tooltipText: "Stop syncing — both copies are kept"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (pairRow.pair) root.unsync(pairRow.pair.remote)
      }
    }
  }

  component LoginRow: CursorSurface {
    hasCursor: root.cursorActive && !root.authenticated
    foreground: root.foreground
    implicitHeight: loginContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: root.installed ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: root.installed
      onEntered: root.cursorActive = true
      onClicked: root.login()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        // U+F084 key
        text: "\uF084"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: loginContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.installed ? "Sign in to Proton Drive" : "Proton Drive CLI is not installed"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.installed
            ? "Opens a terminal and your browser — press r when done"
            : "Install the proton-drive-cli-bin package first"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component EntryRow: CursorSurface {
    id: entryRow
    property var row: null
    property int rowIndex: 0

    readonly property bool isUp: !!row && row.kind === "up"
    readonly property var entry: row && row.kind === "entry" ? row.entry : null
    readonly property bool container: isUp || Model.isContainer(entry)
    readonly property bool busy: !!entry && root.busyPath === String(entry.path)
    readonly property string localPath: entry && entry.local ? String(entry.local) : ""

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    // Automatic (rather than Internal) is what makes this a real inter-client
    // drag rather than one that only exists inside our own window.
    Drag.dragType: Drag.Automatic
    Drag.supportedActions: Qt.CopyAction
    Drag.mimeData: entryRow.localPath !== ""
      ? ({ "text/uri-list": Model.fileUri(entryRow.localPath), "text/plain": entryRow.localPath })
      : ({})

    Timer {
      id: dragStartTimer
      // One frame of slack so the shrunken input region reaches the compositor
      // before the drag grabs the pointer; startDrag then blocks until the drop
      // is resolved.
      interval: 24
      repeat: false
      onTriggered: {
        entryRow.Drag.startDrag(Qt.CopyAction)
        root.dragActive = false
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      property real pressX: 0
      property real pressY: 0
      property bool dragArmed: false
      property bool dragStarted: false

      onEntered: root.setCursor(entryRow.rowIndex)
      onPressed: function (mouse) {
        pressX = mouse.x
        pressY = mouse.y
        dragStarted = false
        dragArmed = !entryRow.isUp && !!entryRow.entry && entryRow.entry.type === "file"
      }
      onPositionChanged: function (mouse) {
        if (!pressed || !dragArmed) return
        if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < Style.space(12)) return
        dragArmed = false
        dragStarted = root.beginDragOut(entryRow, entryRow.entry)
        if (dragStarted) dragStartTimer.restart()
      }
      onClicked: {
        // A drag consumed this press; do not also treat it as a click.
        if (dragStarted) { dragStarted = false; return }
        if (entryRow.isUp) root.goUp()
        else if (entryRow.container) root.enter(entryRow.entry)
        else root.download(entryRow.entry)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        // U+F062 arrow-up for the parent row
        text: entryRow.isUp ? "\uF062" : Model.entryGlyph(entryRow.entry)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: entryRow.isUp ? ".." : (entryRow.entry ? String(entryRow.entry.name) : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: entryRow.isUp
            ? "Parent folder"
            : (entryRow.busy ? "Downloading…" : Model.entryMeta(entryRow.entry, root.nowMs))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Per-folder sync control. A folder already inside a synced folder shows
      // it but cannot be clicked \u2014 pairing it again would sync the same bytes
      // twice, through two different state files.
      SyncButton {
        readonly property var syncState: Model.syncStateFor(
          root.syncPairs, entryRow.entry ? entryRow.entry.path : "")

        visible: !entryRow.isUp && !!entryRow.entry && entryRow.entry.type === "folder"
        glyph: "\uF0EC"
        spinning: Model.isBusy(syncState.pair)
        enabled: syncState.kind !== "covered" && !root.syncPicking
        tint: syncState.kind === "self" ? root.foreground : root.dim
        tooltip: syncState.kind === "self"
          ? "Synced with " + Model.plain(syncState.pair.localShort) + " \u2014 sync now"
          : (syncState.kind === "covered"
            ? "Already covered by " + Model.plain(syncState.pair.name)
            : "Keep this folder in step with a local folder")
        Layout.alignment: Qt.AlignVCenter
        onActivated: if (entryRow.entry) root.toggleSync(entryRow.entry.path)
      }

      PanelActionButton {
        // U+F019 download
        visible: !entryRow.isUp && !!entryRow.entry && entryRow.entry.type !== "section"
        iconText: "\uF019"
        tooltipText: entryRow.container ? "Download this folder" : "Download this file"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.downloading
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.download(entryRow.entry)
      }
    }
  }
}
