import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "openvpn3Vpn"

    StringSetting {
        settingKey: "defaultConfig"
        label: I18n.trFor("openvpn3Vpn", "Default profile")
        description: I18n.trFor("openvpn3Vpn", "openvpn3 profile name toggled by right-clicking the bar icon and by the Control Center tile. Leave empty to use the first imported profile.")
        placeholder: "my-vpn"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "pollInterval"
        label: I18n.trFor("openvpn3Vpn", "Refresh interval")
        description: I18n.trFor("openvpn3Vpn", "How often session status is polled while idle. It is polled faster while connecting.")
        options: [
            {
                label: "3 s",
                value: "3"
            },
            {
                label: "5 s",
                value: "5"
            },
            {
                label: "10 s",
                value: "10"
            },
            {
                label: "30 s",
                value: "30"
            }
        ]
        defaultValue: "5"
    }

    ToggleSetting {
        settingKey: "showLabel"
        label: I18n.trFor("openvpn3Vpn", "Show label")
        description: I18n.trFor("openvpn3Vpn", "Show the connected profile name next to the icon in horizontal bars.")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notifications"
        label: I18n.trFor("openvpn3Vpn", "Notifications")
        description: I18n.trFor("openvpn3Vpn", "Show a toast when a VPN connects, disconnects or fails.")
        defaultValue: true
    }
}
