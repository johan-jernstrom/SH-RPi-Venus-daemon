import QtQuick
import Victron.VenusOS

Page {
    id: root
    title: qsTr("Sailor Hat")

    GradientListView {
        model: VisibleItemModel {

            ListText {
                text: qsTr("State")
                dataItem.uid: "dbus/com.victronenergy.sailorhat/State"
            }

            ListText {
                text: qsTr("Shutting down in")
                dataItem.uid: "dbus/com.victronenergy.sailorhat/ShutdownCountdown"
                secondaryText: dataItem.valid ? dataItem.value + " s" : "--"
                preferredVisible: dataItem.valid && dataItem.value > 0
            }

            ListSpinBox {
                text: qsTr("Blackout Time Limit")
                dataItem.uid: "dbus/com.victronenergy.settings/Settings/Sailorhat/BlackoutTimeLimit"
                from: 1
                to: 600
                stepSize: 1
                suffix: " s"
                decimals: 0
                writeAccessLevel: VenusOS.User_AccessType_User
            }

            ListQuantity {
                text: qsTr("Input voltage")
                dataItem.uid: "dbus/com.victronenergy.sailorhat/VoltageIn"
                decimals: 2
                unit: VenusOS.Units_Volt_DC
            }

            ListQuantity {
                text: qsTr("Input current")
                dataItem.uid: "dbus/com.victronenergy.sailorhat/CurrentIn"
                decimals: 2
                unit: VenusOS.Units_Amp
            }
        }
    }
}
