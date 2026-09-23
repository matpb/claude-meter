import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    property alias cfg_showIcon: showIcon.checked
    property alias cfg_monochromeIcon: monochromeIcon.checked
    property alias cfg_showWindowLabels: showWindowLabels.checked
    property alias cfg_panelBars: panelBars.currentIndex
    property alias cfg_showModelWindow: showModelWindow.checked

    Kirigami.FormLayout {
        anchors.left: parent.left
        anchors.right: parent.right

        QQC2.CheckBox {
            id: showIcon
            Kirigami.FormData.label: i18n("Panel:")
            text: i18n("Show the Claude icon")
        }

        QQC2.CheckBox {
            id: monochromeIcon
            enabled: showIcon.checked
            text: i18n("Tint it to match the panel instead of the brand colour")
        }

        QQC2.CheckBox {
            id: showWindowLabels
            text: i18n("Show the window labels (\"5h\", \"7d\")")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: showModelWindow
            Kirigami.FormData.label: i18n("Per-model window:")
            text: i18n("Show the per-model window (Fable)")
        }

        QQC2.ComboBox {
            id: panelBars
            Kirigami.FormData.label: i18n("Bars in the panel:")
            enabled: showModelWindow.checked
            model: [
                i18n("5-hour and 7-day"),
                i18n("5-hour, 7-day and per-model (Fable)"),
                i18n("5-hour and per-model (Fable)")
            ]
        }

        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.7
            wrapMode: Text.WordWrap
            text: i18n("The per-model window is hidden unless enabled above, and even then only appears when your plan has one. With it off, the panel always shows 5-hour and 7-day.")
        }
    }
}
