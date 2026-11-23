import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets
import qs.Modules.Plugins
import "Ovpn3.js" as Ovpn3

PluginComponent {
    id: root

    // ---- settings ----------------------------------------------------------
    readonly property string defaultConfigSetting: String(pluginData.defaultConfig || "").trim()
    readonly property int pollSeconds: Math.max(2, parseInt(pluginData.pollInterval || "5") || 5)
    readonly property bool showLabel: pluginData.showLabel === true || pluginData.showLabel === "true"
    readonly property bool notificationsEnabled: pluginData.notifications !== false && pluginData.notifications !== "false"

    // ---- state -------------------------------------------------------------
    property bool available: true
    property var configs: []
    property var sessions: []
    readonly property var rows: Ovpn3.buildRows(configs, sessions)
    property string busyConfig: ""
    property var lastStates: ({})
    property bool initialized: false
    readonly property string instanceKey: Math.random().toString(36).slice(2, 10)

    readonly property string defaultConfig: defaultConfigSetting || (configs.length > 0 ? configs[0].name : "")
    readonly property string overall: Ovpn3.overallState(rows)
    readonly property bool isConnected: overall === "connected"
    readonly property bool isBusy: busyConfig !== "" || overall === "auth" || overall === "connecting"
    readonly property var connectedNames: rows.filter(r => r.state === "connected").map(r => r.name)

    readonly property string statusSummary: {
        if (!available)
            return I18n.trFor("openvpn3Vpn", "openvpn3 is not installed");
        if (overall === "auth")
            return I18n.trFor("openvpn3Vpn", "Waiting for sign-in in your browser");
        if (busyConfig !== "" || overall === "connecting")
            return I18n.trFor("openvpn3Vpn", "Connecting…");
        if (isConnected)
            return I18n.trFor("openvpn3Vpn", "Connected • %1").arg(connectedNames.join(", "));
        return I18n.trFor("openvpn3Vpn", "Disconnected");
    }

    readonly property string pillIcon: {
        if (!available)
            return "error";
        if (isConnected || isBusy)
            return "vpn_lock";
        return "vpn_key_off";
    }
    readonly property color pillColor: {
        if (!available)
            return Theme.error;
        if (isConnected || isBusy)
            return Theme.primary;
        return Theme.widgetIconColor;
    }
    readonly property string pillLabel: {
        if (isConnected)
            return connectedNames.join(", ");
        if (isBusy)
            return busyConfig || I18n.trFor("openvpn3Vpn", "VPN");
        return I18n.trFor("openvpn3Vpn", "VPN");
    }

    // ---- polling -----------------------------------------------------------
    Timer {
        id: pollTimer
        interval: root.isBusy ? 1500 : root.pollSeconds * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function refresh() {
        Proc.runCommand("openvpn3Vpn.configs." + instanceKey, ["sh", "-c", "command -v openvpn3 >/dev/null 2>&1 || exit 127; exec openvpn3 configs-list --json"], (out, code) => {
            if (code === 127) {
                root.available = false;
                return;
            }
            root.available = true;
            if (code === 0)
                root.configs = Ovpn3.parseConfigs(out);
        }, 10);
        Proc.runCommand("openvpn3Vpn.sessions." + instanceKey, ["sh", "-c", "command -v openvpn3 >/dev/null 2>&1 || exit 127; exec openvpn3 sessions-list"], (out, code) => {
            if (code !== 0)
                return;
            root.sessions = Ovpn3.parseSessions(out);
            root.checkTransitions();
        }, 10);
    }

    function checkTransitions() {
        const next = {};
        for (const r of rows) {
            next[r.name] = r.state;
            const prev = lastStates[r.name];
            if (!initialized || !notificationsEnabled || prev === undefined || prev === r.state)
                continue;
            if (r.state === "connected")
                ToastService.showInfo(I18n.trFor("openvpn3Vpn", "VPN connected"), r.name);
            else if (prev === "connected" && !Ovpn3.isActive(r.state))
                ToastService.showInfo(I18n.trFor("openvpn3Vpn", "VPN disconnected"), r.name);
            else if (r.state === "failed")
                ToastService.showError(I18n.trFor("openvpn3Vpn", "VPN connection failed"), r.name + (r.status ? ": " + r.status : ""));
        }
        // Profiles that vanished from the list were disconnected too.
        for (const name in lastStates) {
            if (initialized && notificationsEnabled && next[name] === undefined && lastStates[name] === "connected")
                ToastService.showInfo(I18n.trFor("openvpn3Vpn", "VPN disconnected"), name);
        }
        lastStates = next;
        initialized = true;
        if (busyConfig !== "" && !connectProc.running) {
            const row = rows.find(r => r.name === busyConfig);
            if (!row || !Ovpn3.isActive(row.state) || row.state === "connected")
                busyConfig = "";
        }
    }

    // ---- actions -----------------------------------------------------------
    function rowFor(name) {
        return rows.find(r => r.name === name) || null;
    }

    function toggleConfig(name) {
        if (!name) {
            ToastService.showError(I18n.trFor("openvpn3Vpn", "No OpenVPN 3 profile"), I18n.trFor("openvpn3Vpn", "Import one with: openvpn3 config-import --config FILE --name NAME --persistent"));
            return;
        }
        const row = rowFor(name);
        if (row && Ovpn3.isActive(row.state))
            disconnectConfig(name);
        else
            connectConfig(name);
    }

    function connectConfig(name) {
        if (!available || connectProc.running)
            return;
        busyConfig = name;
        connectProc.configName = name;
        connectProc.lines = [];
        connectProc.urlFallback = false;
        connectProc.running = true;
    }

    function disconnectConfig(name) {
        const row = rowFor(name);
        if (!row || row.sessionPaths.length === 0)
            return;
        busyConfig = name;
        let pending = row.sessionPaths.length;
        for (const path of row.sessionPaths) {
            Proc.runCommand("openvpn3Vpn.disconnect." + path, ["openvpn3", "session-manage", "--path", path, "--disconnect"], (out, code) => {
                pending -= 1;
                if (pending <= 0) {
                    root.busyConfig = "";
                    root.refresh();
                }
            }, 10);
        }
    }

    function handleConnectLine(line) {
        connectProc.lines.push(line);
        // openvpn3 opens the sign-in page itself through the desktop portal /
        // xdg-open. It only prints the URL when that fails, so open it then.
        if (line.indexOf("Could not open the URL") !== -1) {
            connectProc.urlFallback = true;
            return;
        }
        if (connectProc.urlFallback) {
            const url = Ovpn3.extractUrl(line);
            if (url !== "") {
                connectProc.urlFallback = false;
                Qt.openUrlExternally(url);
            }
        }
    }

    Process {
        id: connectProc

        property string configName: ""
        property var lines: []
        property bool urlFallback: false

        // Runs in the foreground (no --background) so openvpn3 handles the
        // web/SAML/OAuth flow and opens the browser. It exits once the
        // session is connected or handed over to external authentication.
        command: ["openvpn3", "session-start", "--config", configName]
        running: false

        stdout: SplitParser {
            onRead: data => root.handleConnectLine(data)
        }
        stderr: SplitParser {
            onRead: data => root.handleConnectLine(data)
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                const detail = connectProc.lines.filter(l => l.trim() !== "").slice(-3).join("\n");
                ToastService.showError(I18n.trFor("openvpn3Vpn", "Could not start %1").arg(connectProc.configName), detail || I18n.trFor("openvpn3Vpn", "openvpn3 exited with code %1").arg(exitCode));
                root.busyConfig = "";
            }
            root.refresh();
        }
    }

    // ---- clicks ------------------------------------------------------------
    pillRightClickAction: () => root.toggleConfig(root.defaultConfig)

    // ---- Control Center tile ----------------------------------------------
    ccWidgetIcon: root.pillIcon
    ccWidgetPrimaryText: root.defaultConfig || I18n.trFor("openvpn3Vpn", "OpenVPN 3")
    ccWidgetSecondaryText: root.statusSummary
    ccWidgetIsActive: root.isConnected
    onCcWidgetToggled: root.toggleConfig(root.defaultConfig)

    // ---- bar pills ---------------------------------------------------------
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                id: hIcon
                name: root.pillIcon
                size: root.iconSize
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter

                SequentialAnimation {
                    running: root.isBusy
                    loops: Animation.Infinite
                    onStopped: hIcon.opacity = 1
                    NumberAnimation { target: hIcon; property: "opacity"; to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: hIcon; property: "opacity"; to: 1; duration: 700; easing.type: Easing.InOutQuad }
                }
            }

            StyledText {
                visible: root.showLabel
                text: root.pillLabel
                color: root.pillColor
                font.pixelSize: root.textSize
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DIcon {
                id: vIcon
                name: root.pillIcon
                size: root.iconSize
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter

                SequentialAnimation {
                    running: root.isBusy
                    loops: Animation.Infinite
                    onStopped: vIcon.opacity = 1
                    NumberAnimation { target: vIcon; property: "opacity"; to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: vIcon; property: "opacity"; to: 1; duration: 700; easing.type: Easing.InOutQuad }
                }
            }
        }
    }

    // ---- popout ------------------------------------------------------------
    popoutWidth: 380
    popoutHeight: Math.min(560, 150 + Math.max(1, rows.length) * 68)

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: I18n.trFor("openvpn3Vpn", "OpenVPN 3")
            detailsText: root.statusSummary

            Column {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    width: parent.width
                    visible: !root.available
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.trFor("openvpn3Vpn", "Install openvpn3-linux (AUR: openvpn3) and import a profile to use this widget.")
                }

                StyledText {
                    width: parent.width
                    visible: root.available && root.rows.length === 0
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.trFor("openvpn3Vpn", "No profiles imported. Run:\nopenvpn3 config-import --config FILE.ovpn --name NAME --persistent")
                }

                Repeater {
                    model: root.rows

                    delegate: Rectangle {
                        id: rowItem

                        required property var modelData
                        readonly property bool active: Ovpn3.isActive(modelData.state)
                        readonly property bool busy: root.busyConfig === modelData.name || modelData.state === "auth" || modelData.state === "connecting"

                        width: parent.width
                        height: 60
                        radius: Theme.cornerRadius
                        color: modelData.state === "connected" ? Theme.withAlpha(Theme.primary, 0.12) : Theme.withAlpha(Theme.chipSurface, 0.6)

                        DIcon {
                            id: stateIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            size: Theme.iconSize
                            name: rowItem.active ? "vpn_lock" : "vpn_key_off"
                            color: modelData.state === "connected" ? Theme.primary : (modelData.state === "failed" ? Theme.error : Theme.surfaceVariantText)
                        }

                        Column {
                            anchors.left: stateIcon.right
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: actionButton.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: modelData.name + (modelData.name === root.defaultConfig ? "  ★" : "")
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Theme.fontWeightMedium
                            }

                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                text: {
                                    switch (modelData.state) {
                                    case "connected":
                                        return I18n.trFor("openvpn3Vpn", "Connected") + (modelData.device ? " • " + modelData.device : "");
                                    case "auth":
                                        return I18n.trFor("openvpn3Vpn", "Waiting for sign-in in your browser");
                                    case "connecting":
                                        return I18n.trFor("openvpn3Vpn", "Connecting…");
                                    case "paused":
                                        return I18n.trFor("openvpn3Vpn", "Paused");
                                    case "failed":
                                        return modelData.status || I18n.trFor("openvpn3Vpn", "Failed");
                                    default:
                                        return root.busyConfig === modelData.name ? I18n.trFor("openvpn3Vpn", "Starting…") : I18n.trFor("openvpn3Vpn", "Disconnected");
                                    }
                                }
                            }
                        }

                        Rectangle {
                            id: actionButton
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            width: actionText.implicitWidth + Theme.spacingM * 2
                            height: 32
                            radius: Theme.cornerRadius
                            opacity: (root.busyConfig === modelData.name && !rowItem.active) ? 0.5 : 1
                            color: actionArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.25) : Theme.withAlpha(Theme.primary, 0.14)

                            StyledText {
                                id: actionText
                                anchors.centerIn: parent
                                color: Theme.primary
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Theme.fontWeightMedium
                                text: {
                                    if (modelData.state === "connected" || modelData.state === "paused")
                                        return I18n.trFor("openvpn3Vpn", "Disconnect");
                                    if (rowItem.active)
                                        return I18n.trFor("openvpn3Vpn", "Cancel");
                                    return I18n.trFor("openvpn3Vpn", "Connect");
                                }
                            }

                            MouseArea {
                                id: actionArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !(root.busyConfig === modelData.name && !rowItem.active)
                                onClicked: {
                                    if (rowItem.active)
                                        root.disconnectConfig(modelData.name);
                                    else if (modelData.imported)
                                        root.connectConfig(modelData.name);
                                }
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.available && root.rows.length > 0
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.trFor("openvpn3Vpn", "Right-click the bar icon to toggle the default profile (★).")
                }
            }
        }
    }
}
