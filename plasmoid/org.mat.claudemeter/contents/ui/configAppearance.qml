import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    property alias cfg_showIcon: showIcon.checked
    property alias cfg_monochromeIcon: monochromeIcon.checked
    property alias cfg_showWindowLabels: showWindowLabels.checked

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
            text: i18n("Show the \"5h\" and \"7d\" labels")
        }
    }
}
