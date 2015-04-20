{config, pkgs, ...}:

with pkgs.lib;

let
  setupDir = "/home/awsa";

  awfyService = name: dir: {
    description = "Are We Fast Yet daemon (${name})";
    requires = [ "local-fs.target" "httpd.service" ];
    wantedBy = [ "multi-user.target" ];
    stopIfChanged = true;
    path = [ ];
    environment = {
      SHARED_SETUP_DIR = setupDir;
    };

    serviceConfig = {
      ExecStart = "${setupDir}/run-chroot.sh '${setupDir}/arewefastyet/driver/b2g-benchmark.sh ${dir} loop'";
      Type = "simple";
      KillMode = "control-group";
      Restart = "always";
    };
  };
in

{
  fileSystems = {
    # # Mount the partition which is hosting all trees and the chroot
    # # used to build and flash the phones.
    # "/home/awsa" = {
    #   label = "awsa";

    #   # data=journal is the slowest mode as we write things twice,
    #   # when on a single HDD, but this is likely faster when the
    #   # journal is located on an SSD.
    #   options = "noatime,data=journal";
    # };

    "/home/awsa/deb-chroot/sys" = { device = "/sys"; fsType = "none"; options = "bind"; };
    "/home/awsa/deb-chroot/dev" = { device = "/dev"; fsType = "none"; options = "bind"; };
    "/home/awsa/deb-chroot/nix" = { device = "/nix"; fsType = "none"; options = "bind"; };
    "/home/awsa/deb-chroot/proc" = { device = "/proc"; fsType = "none"; options = "bind"; };
    "/home/awsa/deb-chroot/home/awsa" = { device = "/home/awsa"; fsType = "none"; options = "bind"; };
  };

  users.extraUsers = {
    awsa = {
      group = "wheel";
      uid = 29998;
      description = "Are We Fast Yet";
      home = "/home/awsa";
      useDefaultShell = true;
      createHome = true;
    };
  };

  # Detect the device in normal execution mode and also when it is flashed.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="19d2", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", MODE="0666"
  '';

  # Start the adb daemon.
  # pkgs.androidenv.platformTools

  systemd.services.arewefastyet-normal =        awfyService "normal" "${setupDir}/unagi/B2G";
  systemd.services.arewefastyet-ggc =           awfyService "ggc" "${setupDir}/unagi/ggc-b2g";
  systemd.services.arewefastyet-aurora =        awfyService "aurora" "${setupDir}/unagi/aurora-b2g";
  systemd.services.arewefastyet-flame-inbound = awfyService "flame-inbound" "${setupDir}/flame/inbound";
  systemd.services.arewefastyet-flame-ggc =     awfyService "flame-ggc" "${setupDir}/flame/ggc";
  systemd.services.arewefastyet-flame-aurora =  awfyService "flame-aurora" "${setupDir}/flame/aurora";
  systemd.services.arewefastyet-flame-perso =   awfyService "flame-perso" "${setupDir}/flame/personal";

  # ADB commands keep restarting the server, which make connections to
  # it quite ambiguous. This code is used to keep only one "abd -P
  # 5037 fork-server" process alive.

  systemd.services.adb-killer = {
    description = "Kill redundant adb servers.";
    path = [ pkgs.coreutils pkgs.procps pkgs.gnused ];
    script = ''
      kill -15 $(pgrep -f 'adb -P 5037 fork-server' | sed '1d') || true
    '';
    serviceConfig.Type = "oneshot";
  };

  systemd.timers.adb-killer = {
    description = "Kill redundant adb servers.";
    wantedBy = [ "basic.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1min";
      Unit = "adb-killer.service";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
  services.httpd = {
    enable = true;
    adminAddr = "npierron@mozilla.com";
    servedDirs = [ { dir = "${setupDir}/people.mozilla.org"; urlPath = "/"; } ];
  };
}
