/*
 * Claude Meter — KDE Plasma 6 applet
 * Two capsule bars in the panel: your 5-hour and 7-day Claude subscription usage windows.
 * Data comes from the bundled reader (contents/scripts/claude-meter.sh), which fetches your live
 * usage from claude.ai and falls back to an optional Claude Code statusline snapshot when offline.
 *
 * Fill length   = quota used in that window (green -> amber -> red).
 * Vertical tick  = how far through the window we are BY TIME (elapsed).
 *                  fill left of tick = under pace; fill right of tick = burning fast.
 * Dim + clock    = the reading is stale (older than staleSec); shows its age.
 * ↺ marker       = window just rolled over; the live number may be higher.
 */

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ---- state ----
    property var  data5:    ({ pct: 0, reset_in: null })
    property var  data7:    ({ pct: 0, reset_in: null })
    property bool haveData: false
    property int  ageSec:   0
    property string source:  ""                     // "live" (endpoint) or "cache" (statusline fallback)
    readonly property int  staleSec: 600           // reading older than this = stale
    readonly property bool stale:  haveData && ageSec > staleSec
    readonly property bool noData: !haveData
    // Fresh-but-cached is the dangerous state: the statusline rewrites the snapshot every
    // few seconds, so a dead live fetch otherwise renders as a perfectly healthy widget.
    readonly property bool degraded: haveData && source !== "" && source !== "live"
    // The reader ships inside this package (contents/scripts/); resolve its absolute path at runtime
    // so the widget works for any user, from wherever the plasmoid is installed.
    readonly property string meterScript:
        "bash '" + String(Qt.resolvedUrl("../scripts/claude-meter.sh")).replace("file://", "") + "'"

    preferredRepresentation: compactRepresentation
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    toolTipMainText: "Claude Code usage"
    toolTipSubText: root.haveData
        ? root.tipText()
        : "Waiting for the first Claude Code render…"

    // ============================ helpers ============================

    // Continuous green -> amber -> red as usage climbs 0..100 (fallback when no pace reference).
    function barColor(v) {
        var t = Math.max(0, Math.min(100, v)) / 100.0
        var hue = (1.0 - t) * 140.0 / 360.0   // 140deg green -> 0deg red
        var sat = 0.66 + t * 0.16
        return Qt.hsla(hue, sat, 0.55, 1.0)
    }

    // Colour by PACE, not absolute usage: margin = usage% - time%.
    // Comfortably under the clock = green, at the clock = yellow, ahead of it = red.
    function paceColor(pct, timePct) {
        if (timePct === null || timePct === undefined) return barColor(pct)
        var m = pct - timePct                 // >0 = ahead of the clock (burning fast)
        var hue                                // 140=green … 55=yellow … 0=red
        if (m <= -8)      hue = 140
        else if (m < 0)   hue = 55 + (-m / 8) * 85
        else if (m < 8)   hue = 55 * (1 - m / 8)
        else              hue = 0
        return Qt.hsla(hue / 360.0, 0.72, 0.55, 1.0)
    }

    function fmtDur(s) {
        if (s === null || s === undefined) return "—"
        if (s <= 0) return "now"
        var d = Math.floor(s / 86400); s -= d * 86400
        var h = Math.floor(s / 3600);  s -= h * 3600
        var m = Math.floor(s / 60)
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }

    function fmtAge(s) {
        if (s === null || s === undefined) return "—"
        if (s < 60)    return s + "s"
        if (s < 3600)  return Math.floor(s / 60) + "m"
        if (s < 86400) return Math.floor(s / 3600) + "h"
        return Math.floor(s / 86400) + "d"
    }

    // How far through the window we are, by ELAPSED TIME (0..100), from time-left + window length.
    function timePctOf(resetIn, durSec) {
        if (resetIn === null || resetIn === undefined || resetIn <= 0) return null
        var e = (durSec - Math.min(resetIn, durSec)) / durSec * 100.0
        return Math.max(0, Math.min(100, e))
    }

    // Usage vs. time: ahead of, on, or under the clock?
    function paceArrow(pct, timePct) {
        if (timePct === null || timePct === undefined) return ""
        var m = pct - timePct
        if (m > 8)  return "↑"
        if (m < -8) return "↓"
        return "→"
    }

    function paceWord(pct, timePct) {
        if (timePct === null || timePct === undefined) return ""
        var m = pct - timePct
        if (m > 8)  return "burning fast"
        if (m < -8) return "comfortable"
        return "on pace"
    }

    function detailLine(d, active, durSec) {
        if (!active) return "waiting for first Claude Code render…"
        var parts = []
        if (d.reset_in === null || d.reset_in === undefined) parts.push("no reset info")
        else if (d.reset_in <= 0) parts.push("just reset")
        else parts.push("resets in " + fmtDur(d.reset_in))
        var tp = timePctOf(d.reset_in, durSec)
        if (tp !== null) {
            parts.push(Math.round(tp) + "% through window")
            var w = paceWord(Math.max(0, Math.min(100, d.pct)), tp)
            if (w !== "") parts.push(w)
        }
        return parts.join("   ·   ")
    }

    function lineFor(pfx, d, durSec) {
        var pct = Math.round(Math.max(0, Math.min(100, d.pct)))
        var s = pfx + "  " + pct + "%"
        if (d.reset_in !== null && d.reset_in > 0) s += "  ·  resets " + fmtDur(d.reset_in)
        else if (d.reset_in !== null && d.reset_in <= 0) s += "  ·  just reset"
        var tp = timePctOf(d.reset_in, durSec)
        if (tp !== null) s += "  ·  " + Math.round(tp) + "% thru " + paceArrow(pct, tp)
        return s
    }

    function sourceText() {
        if (source === "live") return "live · account-wide"
        return "cached · " + fmtAge(ageSec) + " ago" + (ageSec > staleSec ? " · stale" : "")
             + "\nlive claude.ai fetch unavailable — this machine's Claude Code only"
    }

    function tipText() {
        return lineFor("5h", data5, 18000) + "\n" + lineFor("7d", data7, 604800)
            + "\n" + sourceText()
    }

    // ============================ data source ============================

    Plasma5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            exec.disconnectSource(source)   // let the next poll re-run it
            var out = (data && data.stdout ? String(data.stdout) : "").trim()
            if (out.length === 0) return
            try {
                var j = JSON.parse(out)
                if (j && j.ok) {
                    root.data5    = j.five
                    root.data7    = j.seven
                    root.ageSec   = j.age || 0
                    root.source   = j.source || ""
                    root.haveData = true
                } else {
                    root.haveData = false
                }
            } catch (e) {
                // malformed output — keep the previous values
            }
        }

        function poll() { exec.connectSource(root.meterScript) }
    }

    Timer {
        interval: 90000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: exec.poll()
    }

    Component.onCompleted: exec.poll()

    // ============================ reusable bar ============================

    component MeterBar : Item {
        id: mb
        property string label: ""
        property real   value: 0
        property var    timePct: null    // 0..100 time position (elapsed), or null
        property bool   active: true
        property bool   stale: false
        property bool   justReset: false
        property bool   showValue: true  // inline % label (panel needs it; popup has its own header)

        implicitHeight: Kirigami.Units.gridUnit
        implicitWidth:  Kirigami.Units.gridUnit * 6

        readonly property real  v: Math.max(0, Math.min(100, value))
        readonly property color fillColor: mb.stale
            ? Qt.rgba(0.56, 0.58, 0.63, 1.0)
            : root.paceColor(v, mb.timePct)

        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: mb.label
                visible: mb.label.length > 0
                font.pixelSize: Math.max(8, mb.height * 0.62)
                font.bold: true
                opacity: 0.6
                Layout.preferredWidth: mb.label.length > 0 ? Kirigami.Units.gridUnit * 0.95 : 0
                horizontalAlignment: Text.AlignLeft
                verticalAlignment: Text.AlignVCenter
            }

            Rectangle {
                id: track
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.maximumHeight: Kirigami.Units.gridUnit * 0.9
                Layout.alignment: Qt.AlignVCenter
                radius: height / 2
                color: Qt.rgba(0.5, 0.5, 0.56, 0.28)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.06)

                Rectangle {
                    id: fill
                    height: parent.height
                    width: (!mb.active || mb.v <= 0) ? 0 : parent.width * mb.v / 100.0
                    // Rounded left cap (nests in the track); FLAT right edge so the
                    // exact value is readable. The right corners only round back up as
                    // the fill nears full, to meet the track's rounded right cap.
                    topLeftRadius: height / 2
                    bottomLeftRadius: height / 2
                    topRightRadius: Math.max(0, Math.min(height / 2, width - (parent.width - height / 2)))
                    bottomRightRadius: topRightRadius
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.lighter(mb.fillColor, 1.35) }
                        GradientStop { position: 1.0; color: mb.fillColor }
                    }
                    Behavior on width { NumberAnimation { duration: 550; easing.type: Easing.OutCubic } }
                }

                // time tick: how far through the window we are, by elapsed time
                Rectangle {
                    id: tick
                    visible: mb.active && mb.timePct !== null && mb.timePct !== undefined
                    width: 2
                    height: parent.height + 4
                    y: -2
                    x: Math.max(0, Math.min(parent.width - width,
                                parent.width * Math.min(100, (mb.timePct || 0)) / 100.0 - width / 2))
                    radius: 1
                    color: mb.stale ? Qt.rgba(1, 1, 1, 0.45) : Qt.rgba(1, 1, 1, 0.92)
                    Behavior on x { NumberAnimation { duration: 550; easing.type: Easing.OutCubic } }
                }

                // "just reset" marker — window rolled over; live number may be higher
                PlasmaComponents.Label {
                    visible: mb.justReset && mb.active
                    text: "↺"
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    font.pixelSize: Math.max(7, parent.height * 0.72)
                    font.bold: true
                    color: Qt.rgba(1, 1, 1, 0.75)
                }
            }

            PlasmaComponents.Label {
                visible: mb.showValue
                text: mb.active ? Math.round(mb.v) + "%" : "—"
                font.pixelSize: Math.max(8, mb.height * 0.58)
                font.bold: true
                color: mb.active ? mb.fillColor : Qt.rgba(0.6, 0.6, 0.6, 1)
                Layout.preferredWidth: mb.showValue ? Kirigami.Units.gridUnit * 1.7 : 0
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    // ============================ compact (in panel) ============================

    compactRepresentation: MouseArea {
        id: compactRoot
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Layout.minimumWidth: contentRow.implicitWidth
        Layout.preferredWidth: contentRow.implicitWidth
        Layout.minimumHeight: Kirigami.Units.gridUnit * 1.6

        RowLayout {
            id: contentRow
            anchors.centerIn: parent
            height: Math.min(parent.height - Kirigami.Units.smallSpacing,
                             Kirigami.Units.gridUnit * 2.3)
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                id: brandIcon
                visible: Plasmoid.configuration.showIcon
                source: Qt.resolvedUrl("../icons/claude.svg")
                isMask: Plasmoid.configuration.monochromeIcon
                color: Kirigami.Theme.textColor
                Layout.preferredWidth: visible ? Math.round(contentRow.height * 0.72) : 0
                Layout.preferredHeight: Layout.preferredWidth
                Layout.alignment: Qt.AlignVCenter
                opacity: root.stale ? 0.5 : 1.0
                Behavior on opacity { NumberAnimation { duration: 400 } }
            }

            ColumnLayout {
                id: barsCol
                Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                Layout.fillHeight: true
                spacing: Kirigami.Units.smallSpacing
                opacity: root.stale ? 0.5 : 1.0
                Behavior on opacity { NumberAnimation { duration: 400 } }

                MeterBar {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    label: Plasmoid.configuration.showWindowLabels ? "5h" : ""
                    active: root.haveData
                    stale: root.stale
                    value: root.data5.pct
                    timePct: root.timePctOf(root.data5.reset_in, 18000)
                    justReset: root.haveData && root.data5.reset_in !== null && root.data5.reset_in <= 0
                }
                MeterBar {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    label: Plasmoid.configuration.showWindowLabels ? "7d" : ""
                    active: root.haveData
                    stale: root.stale
                    value: root.data7.pct
                    timePct: root.timePctOf(root.data7.reset_in, 604800)
                    justReset: root.haveData && root.data7.reset_in !== null && root.data7.reset_in <= 0
                }
            }

            // staleness / no-data badge — only occupies space when relevant
            RowLayout {
                visible: root.stale || root.noData || root.degraded
                Layout.fillHeight: true
                spacing: 2
                Kirigami.Icon {
                    source: root.noData ? "documentinfo" : root.stale ? "clock" : "offline"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    Layout.alignment: Qt.AlignVCenter
                    opacity: 0.75
                }
                PlasmaComponents.Label {
                    text: root.noData ? "no data" : root.stale ? root.fmtAge(root.ageSec) : "cached"
                    font.pixelSize: Math.max(8, contentRow.height * 0.36)
                    opacity: 0.75
                    Layout.alignment: Qt.AlignVCenter
                }
            }
        }
    }

    // ============================ full (popup) ============================

    component WindowBlock : ColumnLayout {
        id: wb
        property string title: ""
        property var    d: ({ pct: 0, reset_in: null })
        property bool   active: true
        property real   windowSec: 18000
        spacing: Kirigami.Units.smallSpacing
        Layout.fillWidth: true

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.Label {
                text: wb.title
                opacity: 0.8
                font.pixelSize: Kirigami.Units.gridUnit * 0.82
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.Label {
                text: wb.active ? Math.round(Math.max(0, Math.min(100, wb.d.pct))) + "%" : "—"
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
                color: wb.active ? (root.stale ? Qt.rgba(0.62, 0.64, 0.68, 1)
                                                : root.paceColor(wb.d.pct, root.timePctOf(wb.d.reset_in, wb.windowSec)))
                                 : Qt.rgba(0.6, 0.6, 0.6, 1)
            }
        }

        MeterBar {
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.05
            label: ""
            showValue: false
            active: wb.active
            stale: root.stale
            value: wb.d.pct
            timePct: root.timePctOf(wb.d.reset_in, wb.windowSec)
            justReset: wb.active && wb.d.reset_in !== null && wb.d.reset_in <= 0
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            opacity: 0.6
            wrapMode: Text.WordWrap
            font.pixelSize: Kirigami.Units.gridUnit * 0.72
            text: root.detailLine(wb.d, wb.active, wb.windowSec)
        }
    }

    fullRepresentation: Item {
        Layout.minimumWidth:  Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        Layout.preferredWidth:  Kirigami.Units.gridUnit * 20
        Layout.preferredHeight: Kirigami.Units.gridUnit * 13

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: Qt.resolvedUrl("../icons/claude.svg")
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                }
                ColumnLayout {
                    spacing: 0
                    PlasmaComponents.Label {
                        text: "Claude Code"
                        font.bold: true
                        font.pixelSize: Kirigami.Units.gridUnit * 1.0
                    }
                    PlasmaComponents.Label {
                        text: "quota usage"
                        opacity: 0.6
                        font.pixelSize: Kirigami.Units.gridUnit * 0.72
                    }
                }
                Item { Layout.fillWidth: true }
            }

            WindowBlock {
                title: "5-hour window"
                d: root.data5
                active: root.haveData
                windowSec: 18000
            }

            WindowBlock {
                title: "7-day window"
                d: root.data7
                active: root.haveData
                windowSec: 604800
            }

            Item { Layout.fillHeight: true }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                opacity: 0.5
                font.pixelSize: Kirigami.Units.gridUnit * 0.72
                text: root.haveData
                    ? (root.source === "live"
                        ? "live · just now"
                        : ("cached · updated " + root.fmtAge(root.ageSec) + " ago"
                           + (root.ageSec > root.staleSec ? "  ·  stale" : "")
                           + "  ·  log in to claude.ai for account-wide numbers"))
                    : "no data yet — run Claude Code once"
            }
        }
    }
}
