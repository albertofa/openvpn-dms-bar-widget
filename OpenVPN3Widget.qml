import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets
import qs.Modals.Common
import qs.Modals.FileBrowser
import qs.Modules.ControlCenter
import qs.Modules.ControlCenter.Widgets
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

    // ---- import ------------------------------------------------------------
    property bool importing: false

    function profileNameFromPath(path) {
        const base = String(path).split("/").pop().replace(/\.(ovpn|conf)$/i, "");
        const name = base.trim().replace(/\s+/g, "-").replace(/[^A-Za-z0-9._-]/g, "");
        return name || "vpn";
    }

    function openImportDialog() {
        // The popout is a layer surface holding keyboard focus. If the file
        // browser window maps while it is still closing, the compositor does
        // not focus the new window, so wait for the popout to be gone first.
        importOpenTimer.restart();
    }

    Timer {
        id: importOpenTimer
        interval: 350
        repeat: false
        onTriggered: {
            importBrowserLoader.active = true;
            if (importBrowserLoader.item)
                importBrowserLoader.item.open();
        }
    }

    function importProfile(path) {
        if (!path || importing)
            return;
        const localPath = String(path).replace(/^file:\/\//, "");
        const name = profileNameFromPath(localPath);
        // Importing the same name twice makes `session-start --config NAME`
        // ambiguous, so refuse instead of creating a duplicate.
        if (configs.some(c => c.name === name)) {
            ToastService.showError(I18n.trFor("openvpn3Vpn", "Profile already exists"), I18n.trFor("openvpn3Vpn", "A profile named \"%1\" is already imported. Remove it first or rename the file.").arg(name));
            return;
        }
        importing = true;
        Proc.runCommand("openvpn3Vpn.import." + instanceKey, ["sh", "-c", "openvpn3 config-import --config \"$1\" --name \"$2\" --persistent 2>&1", "sh", localPath, name], (out, code) => {
            root.importing = false;
            if (code === 0) {
                ToastService.showInfo(I18n.trFor("openvpn3Vpn", "VPN profile imported"), name);
            } else {
                const detail = String(out || "").split("\n").filter(l => l.trim() !== "").slice(-3).join("\n");
                ToastService.showError(I18n.trFor("openvpn3Vpn", "Could not import %1").arg(name), detail || I18n.trFor("openvpn3Vpn", "openvpn3 exited with code %1").arg(code));
            }
            root.refresh();
        }, 10);
    }

    LazyLoader {
        id: importBrowserLoader
        active: false

        FileBrowserModal {
            browserTitle: I18n.trFor("openvpn3Vpn", "Import OpenVPN profile")
            bucket: "vpn"
            filters: ["*.ovpn", "*.conf", "*"]
            onAccepted: paths => root.importProfile(paths[0])
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

    // ---- delete ------------------------------------------------------------
    function deleteProfile(row) {
        if (!row || !row.configPath)
            return;
        const removeConfig = () => {
            Proc.runCommand("openvpn3Vpn.remove." + row.configPath, ["sh", "-c", "openvpn3 config-remove --path \"$1\" --force 2>&1", "sh", row.configPath], (out, code) => {
                if (code === 0) {
                    ToastService.showInfo(I18n.trFor("openvpn3Vpn", "VPN profile deleted"), row.name);
                } else {
                    const detail = String(out || "").split("\n").filter(l => l.trim() !== "").slice(-3).join("\n");
                    ToastService.showError(I18n.trFor("openvpn3Vpn", "Could not delete %1").arg(row.name), detail);
                }
                root.refresh();
            }, 10);
        };
        if (row.sessionPaths.length === 0) {
            removeConfig();
            return;
        }
        // Disconnect running sessions first, then remove the profile.
        let pending = row.sessionPaths.length;
        for (const path of row.sessionPaths) {
            Proc.runCommand("openvpn3Vpn.disconnect." + path, ["openvpn3", "session-manage", "--path", path, "--disconnect"], () => {
                pending -= 1;
                if (pending <= 0)
                    removeConfig();
            }, 10);
        }
    }

    function confirmDelete(row) {
        deleteConfirmLoader.active = true;
        const confirm = deleteConfirmLoader.item;
        if (!confirm)
            return;
        confirm.showWithOptions({
            "title": I18n.trFor("openvpn3Vpn", "Delete VPN"),
            "message": I18n.trFor("openvpn3Vpn", "Delete \"%1\"?").arg(row.name),
            "confirmText": I18n.trFor("openvpn3Vpn", "Delete"),
            "danger": true,
            "onConfirm": () => root.deleteProfile(row)
        });
    }

    function disconnectAll() {
        for (const r of rows) {
            if (Ovpn3.isActive(r.state))
                disconnectConfig(r.name);
        }
    }

    Loader {
        id: deleteConfirmLoader
        active: false
        sourceComponent: ConfirmModal {}
    }

    // ---- popout (mirrors the built-in DMS VPN popout) ------------------------
    popoutWidth: 380

    popoutContent: Component {
        Column {
            id: popout

            property var closePopout: null

            width: parent ? parent.width : root.popoutWidth
            spacing: PopoutMetrics.contentGap

            DButton {
                anchors.right: parent.right
                visible: root.available
                buttonHeight: Theme.buttonHeightXS
                iconName: root.importing ? "sync" : "add"
                iconSize: Theme.iconSizeSmall
                text: I18n.trFor("openvpn3Vpn", "Import")
                variant: "tonal"
                enabled: !root.importing
                onClicked: {
                    if (popout.closePopout)
                        popout.closePopout();
                    root.openImportDialog();
                }
            }

            Column {
                width: parent.width
                spacing: CcMetrics.detailContentGap

                CcGroup {
                    width: parent.width

                    CcListRow {
                        iconName: "vpn_key"
                        iconColor: root.isConnected ? Theme.primary : Theme.surfaceText
                        title: {
                            if (!root.available)
                                return I18n.trFor("openvpn3Vpn", "openvpn3 is not installed");
                            const names = root.connectedNames;
                            if (names.length === 0)
                                return I18n.trFor("openvpn3Vpn", "Active: None");
                            if (names.length === 1)
                                return I18n.trFor("openvpn3Vpn", "Active: %1").arg(names[0]);
                            return I18n.trFor("openvpn3Vpn", "Active: %1 +%2").arg(names[0]).arg(names.length - 1);
                        }

                        DButton {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.isConnected
                            buttonHeight: Theme.buttonHeightXS
                            iconName: "link_off"
                            iconSize: Theme.iconSizeSmall
                            text: I18n.trFor("openvpn3Vpn", "Disconnect")
                            backgroundColor: Theme.errorHover
                            textColor: Theme.error
                            enabled: root.busyConfig === ""
                            onClicked: root.disconnectAll()
                        }
                    }
                }

                CcEmptyState {
                    width: parent.width
                    visible: root.available && root.rows.length === 0
                    iconName: "vpn_key_off"
                    title: I18n.trFor("openvpn3Vpn", "No VPN profiles")
                    subtitle: I18n.trFor("openvpn3Vpn", "Click Import to add a %1 or %2 file").arg(".ovpn").arg(".conf")
                }

                Column {
                    id: profileList
                    width: parent.width
                    visible: root.rows.length > 0
                    spacing: Theme.groupedListGap

                    Repeater {
                        id: profileRepeater
                        model: root.rows

                        delegate: CcListRow {
                            id: profileRow

                            required property var modelData
                            required property int index

                            readonly property bool isActiveState: modelData.state === "connected"
                            readonly property bool isConnecting: root.busyConfig === modelData.name || modelData.state === "auth" || modelData.state === "connecting"
                            readonly property bool hasError: !isConnecting && modelData.state === "failed"

                            width: profileList.width
                            topRadius: index === 0 ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius
                            bottomRadius: index === profileRepeater.count - 1 ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius

                            iconName: isConnecting ? "" : (isActiveState ? "vpn_lock" : (hasError ? "error" : "vpn_key_off"))
                            iconColor: hasError ? Theme.error : contentColor
                            active: isActiveState
                            title: modelData.name
                            subtitle: {
                                if (modelData.state === "auth")
                                    return I18n.trFor("openvpn3Vpn", "Waiting for sign-in in your browser");
                                if (isConnecting)
                                    return I18n.trFor("openvpn3Vpn", "Connecting...");
                                if (hasError)
                                    return modelData.status || I18n.trFor("openvpn3Vpn", "VPN connection failed");
                                if (isActiveState)
                                    return "openvpn3" + (modelData.device ? " • " + modelData.device : "");
                                return modelData.name === root.defaultConfig ? I18n.trFor("openvpn3Vpn", "openvpn3 • default") : "openvpn3";
                            }
                            subtitleColor: isConnecting ? Theme.warning : (hasError ? Theme.error : Theme.surfaceVariantText)
                            clickable: modelData.imported || Ovpn3.isActive(modelData.state)
                            onClicked: {
                                if (Ovpn3.isActive(modelData.state))
                                    root.disconnectConfig(modelData.name);
                                else if (root.busyConfig === "")
                                    root.connectConfig(modelData.name);
                            }

                            leading: DSpinner {
                                size: Theme.iconSizeMedium
                                strokeWidth: CcMetrics.spinnerStroke
                                color: Theme.warning
                                visible: profileRow.isConnecting
                                running: visible
                            }

                            DActionButton {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: Ovpn3.isActive(profileRow.modelData.state)
                                buttonSize: Theme.buttonHeightXS
                                iconSize: Theme.iconSizeMedium
                                iconName: "link_off"
                                Accessible.name: I18n.trFor("openvpn3Vpn", "Disconnect")
                                iconColor: profileRow.contentColor
                                onClicked: root.disconnectConfig(profileRow.modelData.name)
                            }

                            DActionButton {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: profileRow.modelData.imported
                                buttonSize: Theme.buttonHeightXS
                                iconSize: Theme.iconSizeMedium
                                iconName: "delete"
                                iconColor: Theme.error
                                Accessible.name: I18n.trFor("openvpn3Vpn", "Delete")
                                onClicked: {
                                    if (popout.closePopout)
                                        popout.closePopout();
                                    root.confirmDelete(profileRow.modelData);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
