{config, pkgs, ...}:

with pkgs.lib;

let
  awfyService = name: dir: {
    description = "Are We Fast Yet daemon (${name})";
    wantedBy = [ "multi-user.target" ];
    stopIfChanged = true;
    path = [ ];

    serviceConfig = {
      ExecStart = "/home/awsa/run-chroot.sh './run-benchmark.sh ${dir} loop'";
      Restart = "always";
      Type = "simple";
      KillMode = "control-group";
    };
  };
in

{
  fileSystems = {
    # Check devices result for Are We Fast Yet?
    "/home/awsa" = { label = "awsa"; neededForBoot = true; };
  };

  users.extraUsers = [
    { name = "awsa";
      group = "wheel";
      uid = 29998;
      description = "Are We Fast Yet";
      home = "/home/awsa";
      useDefaultShell = true;
      createHome = true;
    }
  ];

  # Detect the device in normal execution mode and also when it is flashed.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="19d2", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", MODE="0666"
  '';

  # Start the adb daemon.
  # pkgs.androidenv.platformTools

  systemd.services.arewefastyet-normal = awfyService "normal" "/home/awsa/unagi/B2G";
  systemd.services.arewefastyet-ggc = awfyService "ggc" "/home/awsa/unagi/ggc-b2g";
  systemd.services.arewefastyet-aurora = awfyService "aurora" "/home/awsa/unagi/aurora-b2g";

  networking.firewall.allowedTCPPorts = [ 80 ];
  services.httpd = {
    enable = true;
    adminAddr = "npierron@mozilla.com";
    servedDirs = [ { dir = "/home/awsa/people.mozilla.org"; urlPath = "/"; } ];
  };
}
