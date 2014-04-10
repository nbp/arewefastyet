{config, pkgs, ...}:

with pkgs.lib;

let
  setupDir = "/home/awsa";

  awfyService = name: dir: {
    description = "Are We Fast Yet daemon (${name})";
    wantedBy = [ "multi-user.target" ];
    stopIfChanged = true;
    path = [ ];
    environment = {
      SHARED_SETUP_DIR = setupDir;
    };

    serviceConfig = {
      ExecStart = "${setupDir}/run-chroot.sh '${setupDir}/arewefastyet/driver/b2g-benchmark.sh ${dir} loop'";
      Restart = "always";
      Type = "simple";
      KillMode = "control-group";
    };
  };
in

{
  fileSystems = {
    # Mount the partition which is hosting all trees and the chroot
    # used to build and flash the phones.
    "/home/awsa" = { label = "awsa"; };
  };

  users.extraUsers = {
    awsa = {
      group = "wheel";
      uid = 29998;
      description = "Are We Fast Yet";
      home = "/home/awsa";
      useDefaultShell = true;
      createHome = true;
    }
  };

  # Detect the device in normal execution mode and also when it is flashed.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="19d2", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", MODE="0666"
  '';

  # Start the adb daemon.
  # pkgs.androidenv.platformTools

  systemd.services.arewefastyet-normal = awfyService "normal" "${setupDir}/unagi/B2G";
  systemd.services.arewefastyet-ggc = awfyService "ggc" "${setupDir}/unagi/ggc-b2g";
  systemd.services.arewefastyet-aurora = awfyService "aurora" "${setupDir}/unagi/aurora-b2g";

  networking.firewall.allowedTCPPorts = [ 80 ];
  services.httpd = {
    enable = true;
    adminAddr = "npierron@mozilla.com";
    servedDirs = [ { dir = "${setupDir}/people.mozilla.org"; urlPath = "/"; } ];
  };
}
