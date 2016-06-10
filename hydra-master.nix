# hydra-master.nix

{ config, pkgs, ... }:

{
  imports = [ ./hydra-common.nix ];

  environment.systemPackages = with pkgs; [
    openssl
  ];

  assertions = pkgs.lib.singleton {
    assertion = pkgs.system == "x86_64-linux";
    message = "unsupported system ${pkgs.system}";
  };

  environment.etc = pkgs.lib.singleton {
    target = "nix/id_buildfarm";
    source = ./id_buildfarm;
    uid = config.ids.uids.hydra;
    gid = config.ids.gids.hydra;
    mode = "0440";
  };

  networking.firewall.allowedTCPPorts = [ 443 80 ];

  nix = {
    maxJobs = 1;
    distributedBuilds = true;
    buildMachines = [
      { hostName = "slave1"; maxJobs = 4; speedFactor = 2; sshKey = "/etc/nix/id_buildfarm"; sshUser = "root"; system = "x86_64-linux"; }
      { hostName = "cardassia"; maxJobs = 8; speedFactor = 2; sshKey = "/etc/nix/id_buildfarm"; sshUser = "jophish"; system = "x86_64-darwin"; }
    ];
    extraOptions = "auto-optimise-store = true";
  };

  # for sending emails (optional)
  services.postfix = {
    enable = true;
    setSendmail = true;
  };

  # frontend http/https server
  services.nginx.enable = true;
  services.nginx.config = ''
    #user  nobody;
    worker_processes  1;

    error_log  logs/error.log;
    #error_log  logs/error.log  notice;
    #error_log  logs/error.log  info;

    pid        logs/nginx.pid;


    events {
      worker_connections  1024;
    }


    http {
      log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                        '$status $body_bytes_sent "$http_referer" '
                        '"$http_user_agent" "$http_x_forwarded_for"';

      access_log  logs/access.log  main;

      sendfile        on;
      #tcp_nopush     on;

      #keepalive_timeout  0;
      keepalive_timeout  65;

      #gzip  on;

      # include /root/hydra.nginx;
      # ssl, mostly for people that are going to need to login to Hydra,
      #      we do not want to send passwords as plain text
      server {
        listen 0.0.0.0:443 ssl;
        server_name hydra-ssl;
        keepalive_timeout    70;

        ssl_session_cache    shared:SSL:10m;
        ssl_session_timeout  10m;
        ssl_certificate     /root/ssl/hydra.crt;
        ssl_certificate_key /root/ssl/hydra.key;

        ### We want full access to SSL via backend ###
        location / {
          proxy_pass http://127.0.0.1:3000/;

          ### force timeouts if one of backend is died ##
          proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;

          ### Set headers ####
          proxy_set_header        Accept-Encoding   "";
          proxy_set_header        Host            $host;
          proxy_set_header        X-Real-IP       $remote_addr;
          proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;

          ### Most PHP, Python, Rails, Java App can use this header ###
          #proxy_set_header X-Forwarded-Proto https;##
          #This is better##
          proxy_set_header        X-Forwarded-Proto $scheme;
          add_header              Front-End-Https   on;

          ### By default we don't want to redirect it ####
          proxy_redirect     off;
        }
      }

      # redirect http to https
      server {
        listen 0.0.0.0:80;
        server_name hydra-ssl;
        rewrite ^ https://$server_name$request_uri? permanent;
      }

      # for normal folks
      server {
        listen 0.0.0.0:80;
        server_name hydra;

        location / {
          proxy_pass http://127.0.0.1:3000/;
          proxy_set_header        Host            $host;
          proxy_set_header        X-Real-IP       $remote_addr;
          proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
        }
      }
  }
  '';

  services.hydra = {
    enable = true;
    # dbi = "dbi:Pg:dbname=hydra;host=localhost;user=hydra;";
    hydraURL = "http://hydra/";
    listenHost = "localhost";
    port = 3000;
    minimumDiskFree = 5;  # in GB
    minimumDiskFreeEvaluator = 2;
    notificationSender = "hydra@yourserver.com";
    buildMachinesFiles = [ "/etc/nix/machines" ];
    logo = null;
    debugServer = false;
  };

  services.postgresql = {
    package = pkgs.postgresql94;
    dataDir = "/var/db/postgresql-${config.services.postgresql.package.psqlSchema}";
  };

  systemd.services.hydra-manual-setup = {
    description = "Create Admin User for Hydra";
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    wantedBy = [ "multi-user.target" ];
    requires = [ "hydra-init.service" ];
    after = [ "hydra-init.service" ];
    environment = config.systemd.services.hydra-init.environment;
    script = ''
      if [ ! -e ~hydra/.setup-is-complete ]; then
        # Create senf signed cet
        mkdir -p /root/ssl
        openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -keyout /root/ssl/hydra.key -out /root/ssl/hydra.crt -subj "/C=UK/ST=Cambs/L=House/O=OrgName/OU=IT Department/CN=example.com"
        # create admin user
        /run/current-system/sw/bin/hydra-create-user alice --full-name 'Alice Q. User' --email-address 'alice@example.org' --password foobar --role admin
        # create signing keys
        /run/current-system/sw/bin/install -d -m 551 /etc/nix/hydra.example.org-1
        /run/current-system/sw/bin/nix-store --generate-binary-cache-key hydra.example.org-1 /etc/nix/hydra.example.org-1/secret /etc/nix/hydra.example.org-1/public
        /run/current-system/sw/bin/chown -R hydra:hydra /etc/nix/hydra.example.org-1
        /run/current-system/sw/bin/chmod 440 /etc/nix/hydra.example.org-1/secret
        /run/current-system/sw/bin/chmod 444 /etc/nix/hydra.example.org-1/public
        # done
        touch ~hydra/.setup-is-complete
      fi
    '';
  };

  users.users.hydra-www.uid = config.ids.uids.hydra-www;
  users.users.hydra-queue-runner.uid = config.ids.uids.hydra-queue-runner;
  users.users.hydra.uid = config.ids.uids.hydra;
  users.groups.hydra.gid = config.ids.gids.hydra;

}
