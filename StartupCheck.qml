import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("openvpn3Vpn.startupCheck", ["sh", "-c", "command -v openvpn3"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                title: I18n.trFor("openvpn3Vpn", "openvpn3 is required"),
                details: I18n.trFor("openvpn3Vpn", "Install openvpn3-linux (Arch: AUR package openvpn3, Debian/Ubuntu/Fedora: https://community.openvpn.net/openvpn/wiki/OpenVPN3Linux), then re-enable this plugin.")
            });
        });
    }
}
