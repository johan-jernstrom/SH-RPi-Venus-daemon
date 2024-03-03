import QtQuick 1.1
import "utils.js" as Utils
import com.victron.velib 1.0

MbPage
{
	id: root
	title: qsTr("Sailor Hat")
    model: VisibleItemModel
    {
		MbItemValue {
			description: qsTr("State")
			item.bind: Utils.path("com.victronenergy.sailorhat", "/State")
		}

		MbItemValue {
			description: qsTr("Shutting down in")
			property VBusItem stateItem: VBusItem { bind: Utils.path("com.victronenergy.sailorhat", "/ShutdownCountdown") }
			item {
				bind: Utils.path("com.victronenergy.sailorhat", "/ShutdownCountdown")
				decimals: 0
				unit: " seconds"
			}
			show: stateItem.value>0
		}

		MbSpinBox {
            description: qsTr ("Blackout Time Limit")
			item
			{
				bind: Utils.path("com.victronenergy.settings/Settings/Sailorhat", "/BlackoutTimeLimit")
				unit: " seconds"
				decimals: 0
				step: 1
				min: 1
				max: 600
			}
			writeAccessLevel: User.AccessUser
        }

		MbItemValue {
			description: qsTr("Input voltage")
			item {
				bind: Utils.path("com.victronenergy.sailorhat", "/VoltageIn")
				decimals: 2
				unit: "V"
			}
		}

		MbItemValue {
			description: qsTr("Input current")
			item {
				bind: Utils.path("com.victronenergy.sailorhat", "/CurrentIn")
				decimals: 2
				unit: "A"
			}
		}
    }
}