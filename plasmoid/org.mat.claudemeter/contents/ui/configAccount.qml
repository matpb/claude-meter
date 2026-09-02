import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Dialogs
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

KCM.SimpleKCM {
    id: page

    property alias cfg_accountLabel: accountLabel.text
    property string cfg_cookiesPath
    property alias cfg_usageDir: usageDir.text
    property string cfg_iconPath

    readonly property string readerScript:
        String(Qt.resolvedUrl("../scripts/claude-meter.sh")).replace("file://", "")

    // [{path,label}] from `claude-meter.sh --list-profiles`; index 0 is "auto", last is "custom"
    property var profiles: []

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function syncProfileBox() {
        var idx = 0
        if (cfg_cookiesPath !== "") {
            idx = profiles.length + 1
            for (var i = 0; i < profiles.length; i++)
                if (profiles[i].path === cfg_cookiesPath) { idx = i + 1; break }
        }
        profileBox.currentIndex = idx
    }

    Plasma5Support.DataSource {
        id: lister
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            lister.disconnectSource(source)
            try { page.profiles = JSON.parse(String(data.stdout || "[]")) } catch (e) { page.profiles = [] }
            page.syncProfileBox()
        }
    }
    Component.onCompleted: lister.connectSource("bash " + shq(readerScript) + " --list-profiles")

    FileDialog {
        id: iconDialog
        title: i18n("Choose an icon")
        nameFilters: [i18n("Images (*.svg *.svgz *.png)"), i18n("All files (*)")]
        onAccepted: page.cfg_iconPath = String(selectedFile).replace(/^file:\/\//, "")
    }

    Kirigami.FormLayout {
        anchors.left: parent.left
        anchors.right: parent.right

        QQC2.TextField {
            id: accountLabel
            Kirigami.FormData.label: i18n("Account name:")
            placeholderText: i18n("e.g. Personal, Work")
            Layout.fillWidth: true
        }
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.7
            wrapMode: Text.WordWrap
            text: i18n("Shown in the hover text and the popup. Add one Claude Meter per subscription and name each.")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            id: profileBox
            Kirigami.FormData.label: i18n("Browser profile:")
            Layout.fillWidth: true
            model: [i18n("Auto-detect (first profile logged into claude.ai)")]
                   .concat(page.profiles.map(p => p.label))
                   .concat([i18n("Custom cookie database…")])
            onActivated: function(index) {
                if (index === 0) page.cfg_cookiesPath = ""
                else if (index <= page.profiles.length) page.cfg_cookiesPath = page.profiles[index - 1].path
            }
        }
        QQC2.TextField {
            id: cookiesPath
            Kirigami.FormData.label: i18n("Cookie database:")
            Layout.fillWidth: true
            visible: profileBox.currentIndex === page.profiles.length + 1
            text: page.cfg_cookiesPath
            placeholderText: i18n("/path/to/Profile/Cookies")
            onTextEdited: page.cfg_cookiesPath = text
        }
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.7
            wrapMode: Text.WordWrap
            text: i18n("Each subscription is a separate claude.ai login, so keep each one in its own browser profile and point its meter here.")
        }

        QQC2.TextField {
            id: usageDir
            Kirigami.FormData.label: i18n("Statusline snapshot dir:")
            Layout.fillWidth: true
            placeholderText: i18n("~/.claude/usage")
        }
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.7
            wrapMode: Text.WordWrap
            text: i18n("Optional offline fallback. If this account runs Claude Code under its own CLAUDE_CONFIG_DIR, use <that dir>/usage.")
        }

        Item { Kirigami.FormData.isSection: true }

        RowLayout {
            Kirigami.FormData.label: i18n("Panel icon:")
            Layout.fillWidth: true
            Kirigami.Icon {
                source: page.cfg_iconPath !== "" ? page.cfg_iconPath : Qt.resolvedUrl("../icons/claude.svg")
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            }
            QQC2.Label {
                Layout.fillWidth: true
                elide: Text.ElideMiddle
                opacity: page.cfg_iconPath !== "" ? 1 : 0.7
                text: page.cfg_iconPath !== "" ? page.cfg_iconPath : i18n("Claude (default)")
            }
            QQC2.Button {
                icon.name: "document-open"
                text: i18n("Choose…")
                onClicked: iconDialog.open()
            }
            QQC2.Button {
                icon.name: "edit-clear"
                text: i18n("Reset")
                enabled: page.cfg_iconPath !== ""
                onClicked: page.cfg_iconPath = ""
            }
        }
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.7
            wrapMode: Text.WordWrap
            text: i18n("Any SVG or PNG. A different icon per meter is the quickest way to tell two subscriptions apart at a glance.")
        }
    }
}
