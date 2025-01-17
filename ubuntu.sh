#!/bin/bash
#
# Boostraps an ubuntu machine to be used as an agent for microbox

# exit if any any command fails
set -e

set -o pipefail

# todo:
# set timezone

# set globals to defaults for testing
TOKEN="123"
VIP="192.168.0.55"
ID="123"
COMPONENT=""
INTERNAL_IFACE="eth1"
MTU=1450

wait_for_lock() {
  # wait to make sure no package updates are currently running, it'll break the bootstrap script if it is running.
  while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 ; do
    sleep 1
  done
}

arch() {
  dpkg --print-architecture
}

init_system() {
  if [[ -f /sbin/systemctl || -f /bin/systemctl ]]; then
    echo "systemd"
  elif [[ -f /sbin/initctl || -f /bin/initctl ]]; then
    echo "upstart"
  else
    echo "sysvinit"
  fi
}

internal_ip() {
  ip -o -4 addr show ${INTERNAL_IFACE} \
    | grep " ${INTERNAL_IFACE}\\\\" \
      | awk '{print $4}' \
        | awk -F/ '{print $1}'
}

# Use id until we can incorporate app-name as well
fix_ps1() {
  sed -i "s|@\\\h|@${ID}|g" /root/.bashrc
  grep 'export TERM=xterm' /root/.bashrc || echo 'export TERM=xterm' >> /root/.bashrc
}

# Ensure the host is using the expected interface names provided by Odin
ensure_iface_naming_consistency() {
  set +e

  RENAME=false
  # Check for INTERNAL_IFACE in interface list
  ip -o -4 addr show ${INTERNAL_IFACE} > /dev/null
  if [[ $? -ne 0 ]]
  then
    actual_if="$(ip -o -4 addr \
      | grep -vwe lo -e docker0 -e redd0 -e ${VIP} \
        | awk '{print $2}')"
    fix_iface_name "${actual_if}" "${INTERNAL_IFACE}"
    RENAME=true
  fi

  # Check for EXTERNAL_IFACE in interface list
  if [[ -n "${EXTERNAL_IFACE}" ]] # Is one set?
  then
    ip -o -4 addr show ${EXTERNAL_IFACE} > /dev/null
    if [[ $? -ne 0 ]]
    then
      actual_if="$(ip -o -4 addr | grep -w ${VIP} | awk '{print $2}')"
      fix_iface_name "${actual_if}" "${EXTERNAL_IFACE}"
      RENAME=true
    fi
  fi

  if [ $RENAME = "true" ]
  then
    reboot
    exit 1
  fi

  set -e
}

# Modify interface name in udev rules
fix_iface_name() {
  bad_iface=$1
  good_iface=$2

  if [ -e /etc/udev/rules.d/70-persistent-net.rules ]
  then
    sudo sed -i s/${bad_iface}/${good_iface}/g /etc/udev/rules.d/70-persistent-net.rules
  else
    good_mac=$(ip link show ${bad_iface} | grep link/ | awk '{print $2}')
    echo 'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="'${good_mac}'", NAME="'${good_iface}'"' \
      | sudo tee /etc/udev/rules.d/70-persistent-net.rules >/dev/null
  fi

  if [ -e /etc/network/interfaces.d/50-cloud-init.cfg ]
  then
    sudo sed -i s/${bad_iface}/${good_iface}/g /etc/network/interfaces.d/50-cloud-init.cfg
  fi
}

# install version of docker microagent is using
install_docker() {

  # update the package index
  echo '   -> apt-get update'
  time ( wait_for_lock; apt-get -y update )

  # ensure lsb-release is installed
  which lsb_release || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install lsb-release )

  version=$(lsb_release -rs)
  release=$(lsb_release -cs)

  echo '   -> fetch docker'
  time wget -O /tmp/docker-ce_23.0.3.deb \
    https://download.docker.com/linux/ubuntu/dists/${release}/pool/stable/$(arch)/docker-ce_23.0.3-1~ubuntu.${version}~${release}_$(arch).deb

  # ensure the old repo is purged
  echo '   -> remove old docker'
  time ( wait_for_lock; dpkg --purge lxc-docker docker-engine )

  # install docker deps
  echo '   -> install docker deps'
  time ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install libltdl7 libseccomp2 )

  # # install aufs kernel module
  # if [ ! -f /lib/modules/$(uname -r)/kernel/fs/aufs/aufs.ko ]; then
  #   # make parent directory
  #   [ -d /lib/modules/$(uname -r)/kernel/fs/aufs ] || mkdir -p /lib/modules/$(uname -r)/kernel/fs/aufs

  #   # get aufs kernel module
  #   wget -qq -O /lib/modules/$(uname -r)/kernel/fs/aufs/aufs.ko \
  #   https://s3.amazonaws.com/tools.microbox.cloud/aufs-kernel/$(uname -r)-aufs.ko || \
  #   ( wait_for_lock; sudo apt-get install -y linux-image-extra-$(uname -r) linux-image-extra-virtual )
  # fi

  # # enable use of aufs
  # echo '   -> install aufs'
  # modprobe aufs || ( time depmod && time modprobe aufs )

  # set docker options
  cat > /etc/default/docker <<'END'
DOCKER_OPTS="--iptables=false --storage-driver=overlay2 --dns 8.8.8.8 --dns 8.8.4.4 --dns 1.1.1.1"
END

  if [[ "$(init_system)" = "systemd" ]]; then
    # use docker options
    [ -d /lib/systemd/system/docker.service.d ] || mkdir /lib/systemd/system/docker.service.d
    cat > /lib/systemd/system/docker.service.d/env.conf <<'END'
[Service]
EnvironmentFile=/etc/default/docker
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// $DOCKER_OPTS
END
  fi

  # install docker
  echo '   -> install docker'
  time ( wait_for_lock; dpkg --force-confdef --force-confold -i /tmp/docker-ce_23.0.3.deb || apt-get install -yf )
}

start_docker() {
  # ensure the docker service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service docker status | grep "active (running)"` ]]; then
      service docker start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service docker status | grep start/running` ]]; then
      service docker start
    fi
  fi

  # wait for the docker sock file
  while [ ! -S /var/run/docker.sock ]; do
    sleep 1
  done
}

install_red() {
  if [[ ! -f /tmp/redd_1.0.0-1_$(arch).deb ]]; then
    # fetch packages
    wget -O /tmp/libbframe_1.0.0-1_$(arch).deb https://s3.amazonaws.com/tools.microbox.cloud/deb/libbframe_1.0.0-1_$(arch).deb
    wget -O /tmp/libmsgxchng_1.0.0-1_$(arch).deb https://s3.amazonaws.com/tools.microbox.cloud/deb/libmsgxchng_1.0.0-1_$(arch).deb
    wget -O /tmp/red_1.0.0-1_$(arch).deb https://s3.amazonaws.com/tools.microbox.cloud/deb/red_1.0.0-1_$(arch).deb
    wget -O /tmp/redd_1.0.0-1_$(arch).deb https://s3.amazonaws.com/tools.microbox.cloud/deb/redd_1.0.0-1_$(arch).deb
  fi

  # install dependencies
  wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install libmsgpack3 libuv0.10

  if [[ ! -f /usr/bin/redd ]]; then
    # install packages
    dpkg -i /tmp/libbframe_1.0.0-1_$(arch).deb
    dpkg -i /tmp/libmsgxchng_1.0.0-1_$(arch).deb
    dpkg -i /tmp/red_1.0.0-1_$(arch).deb
    dpkg -i /tmp/redd_1.0.0-1_$(arch).deb
  fi

  # configure redd
  echo "$(redd_conf)" > /etc/redd.conf

  # ensure the redd db path exists
  mkdir -p /var/db/redd

  # create init entry
  if [[ "$(init_system)" = "systemd" ]]; then
    echo "$(redd_systemd_conf)" > /etc/systemd/system/redd.service
    systemctl enable redd.service
  elif [[ "$(init_system)" = "upstart" ]]; then
    echo "$(redd_upstart_conf)" > /etc/init/redd.conf
  fi

  # remove cruft
  rm -f /tmp/libbframe_1.0.0-1_$(arch).deb
  rm -f /tmp/libmsgxchng_1.0.0-1_$(arch).deb
  rm -f /tmp/red_1.0.0-1_$(arch).deb
  rm -f /tmp/redd_1.0.0-1_$(arch).deb
}

start_redd() {
  # ensure the redd service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service redd status | grep "active (running)"` ]]; then
      service redd start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service redd status | grep start/running` ]]; then
      service redd start
    fi
  fi

  # wait for redd to be available
  while [ ! `red ping | grep pong` ]; do
    sleep 1
  done
}

install_bridgeutils() {
  if [[ ! -f /sbin/brctl ]]; then
    wait_for_lock
    apt-get install -y bridge-utils
  fi
}

install_nfsutils() {
  wait_for_lock
  apt-get install -y nfs-common
}

create_docker_network() {
  if [[ ! `docker network ls | grep microbox` ]]; then
    # create a docker network
    docker network create \
      --driver=bridge --subnet=192.168.0.0/16 \
      --opt="com.docker.network.driver.mtu=${MTU}" \
      --opt="com.docker.network.bridge.name=redd0" \
      --gateway=${VIP} \
      microbox
  fi
}

create_vxlan_bridge() {
  # create service entry and configuration
  if [[ "$(init_system)" = "systemd" ]]; then
    echo "$(vxlan_systemd_conf)" > /etc/systemd/system/vxlan.service
    systemctl enable vxlan.service
  elif [[ "$(init_system)" = "upstart" ]]; then
    echo "$(vxlan_upstart_conf)" > /etc/init/vxlan.conf
  fi

  # create bridge script
  if [[ ! -f /usr/local/bin/enable-vxlan-bridge.sh ]]; then
    # create the utility
    echo "$(vxlan_bridge)" > /usr/local/bin/enable-vxlan-bridge.sh
  fi

  # update permissions
  chmod 755 /usr/local/bin/enable-vxlan-bridge.sh
}

start_vxlan_bridge() {
  # ensure the vxlan service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service vxlan status | grep "active (running)"` ]]; then
      service vxlan start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service vxlan status | grep start/running` ]]; then
      service vxlan start
    fi
  fi
}

install_microagent() {
  # ensure the microagent service is stopped
  running="false"
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ `service microagent status | grep "active (running)"` ]]; then
      running="true"
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ `service microagent status | grep start/running` ]]; then
      running="true"
    fi
  fi
  if [[ $running = "false" ]]; then
    # download microagent
    curl \
      -f \
      -k \
      -o /usr/local/bin/microagent \
      https://s3.amazonaws.com/tools.microbox.cloud/microagent/linux/$(arch)/microagent-v2

    # update permissions
    chmod 755 /usr/local/bin/microagent

    # download md5
    mkdir -p /var/microbox
    curl \
      -f \
      -k \
      -o /var/microbox/microagent.md5 \
      https://s3.amazonaws.com/tools.microbox.cloud/microagent/linux/$(arch)/microagent-v2.md5

    if [[ "$(cat /var/microbox/microagent.md5)" != "$(md5sum /usr/local/bin/microagent | cut -f1 -d' ')" ]]; then
      echo "microagent MD5s do not match!";
      exit 1;
    fi

    # create db
    mkdir -p /var/db/microagent

    # generate config file
    mkdir -p /etc/microagent
    echo "$(microagent_json)" > /etc/microagent/config.json

    # create init script
    if [[ "$(init_system)" = "systemd" ]]; then
      echo "View logs with 'journalctl -fu microagent'">> /var/log/microagent.log
      echo "$(microagent_systemd_conf)" > /etc/systemd/system/microagent.service
      systemctl enable microagent.service
    elif [[ "$(init_system)" = "upstart" ]]; then
      echo "$(microagent_upstart_conf)" > /etc/init/microagent.conf
    fi

    # create update script
    echo "$(microagent_update)" > /usr/local/bin/microagent-update

    # update permissions
    chmod 755 /usr/local/bin/microagent-update
  fi
}

start_microagent() {
  # ensure the firewall service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service microagent status | grep "active (running)"` ]]; then
      service microagent start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service microagent status | grep start/running` ]]; then
      service microagent start
    fi
  fi
}

configure_modloader() {
  if [[ "$(init_system)" = "systemd" ]]; then
    echo 'ip_vs' > /etc/modules-load.d/microbox-ipvs.conf
  elif [[ "$(init_system)" = "upstart" ]]; then
    grep 'ip_vs' /tmpetc/modules &> /dev/null || echo 'ip_vs' >> /etc/modules
  fi
}

start_modloader() {
  modprobe ip_vs
}

configure_firewall() {
  # create init script
  if [[ "$(init_system)" = "systemd" ]]; then
    echo "$(firewall_systemd_conf)" > /etc/systemd/system/firewall.service
    systemctl enable firewall.service
  elif [[ "$(init_system)" = "upstart" ]]; then
    echo "$(firewall_upstart_conf)" > /etc/init/firewall.conf
  fi

  # create firewall script
  echo "$(build_firewall)" > /usr/local/bin/build-firewall.sh

  # update permissions
  chmod 755 /usr/local/bin/build-firewall.sh
}

start_firewall() {
  # ensure the firewall service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service firewall status | grep "active (running)"` ]]; then
      service firewall start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service firewall status | grep start/running` ]]; then
      service firewall start
    fi
  fi
}

# conifgure automatic updates to not update kernel or docker
configure_updates() {
  # Remove extra architectures (will exit 0 but display warning if none)
  # Linode servers have i386 added for convenience(?) but we want fast
  # apt updates.
  wait_for_lock
  dpkg --remove-architecture "$(dpkg --print-foreign-architectures)"

  # trim extra sources for faster apt updates
  sed -i -r '/(-src|backports)/d' /etc/apt/sources.list

  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'END'
// Automatically upgrade packages from these (origin:archive) pairs
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};

// List of packages to not update (regexp are supported)
Unattended-Upgrade::Package-Blacklist {
    "docker-engine";
    "linux-image-*";
    "linux-headers-*";
    "linux-virtual";
//  "linux-image-extra-virtual";
//  "linux-image-virtual";
//  "linux-headers-generic";
//  "linux-headers-virtual";
};
END

# disable auto-updates alltogether
  cat > /etc/apt/apt.conf.d/10periodic <<'END'
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
END
}

redd_conf() {
  cat <<END
daemonize no
pidfile /var/run/redd.pid
logfile /var/log/redd.log
loglevel warning
port 4470
timeout 0

routing-enabled yes

bind 127.0.0.1
udp-listen-address $(internal_ip)
vxlan-interface ${INTERNAL_IFACE}
save-path /var/db/redd
END
}

redd_upstart_conf() {
  cat <<'END'
description "Red vxlan daemon"

oom score never

start on (filesystem and net-device-up IFACE!=lo)
stop on runlevel [!2345]

respawn

kill timeout 20

exec redd /etc/redd.conf
END
}

redd_systemd_conf() {
  cat <<'END'
[Unit]
Description=Red vxlan daemon
After=syslog.target network.target
Before=vxlan.service

[Service]
OOMScoreAdjust=-1000
ExecStart=/usr/bin/redd /etc/redd.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
END
}

vxlan_bridge() {
  cat <<'END'
#!/bin/bash

# wait for redd0
/sbin/ifconfig | /bin/grep redd0 &> /dev/null
while [ $? -ne 0 ]; do
  sleep 1
  /sbin/ifconfig | /bin/grep redd0 &> /dev/null
done

# wait for vxlan0
/sbin/ifconfig | /bin/grep vxlan0 &> /dev/null
while [ $? -ne 0 ]; do
  sleep 1
  /sbin/ifconfig | /bin/grep vxlan0 &> /dev/null
done

/sbin/brctl show redd0 | /bin/grep vxlan0 &> /dev/null
if [ $? -ne 0 ]; then
  # disable mac address learning to ensure broadcasts are always forwarded
  /sbin/brctl setageing redd0 0

  # bridge the network onto the red vxlan
  /sbin/brctl addif redd0 vxlan0
fi
END
}

vxlan_upstart_conf() {
  cat <<'END'
description "Red vxlan to docker bridge"

oom score never

start on runlevel [2345]

exec /usr/local/bin/enable-vxlan-bridge.sh
END
}

vxlan_systemd_conf() {
  cat <<'END'
[Unit]
Description=Red vxlan to docker bridge
After=redd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/enable-vxlan-bridge.sh

[Install]
WantedBy=multi-user.target
END
}

microagent_json() {
  cat <<END
{
  "host_id": "${ID}",
  "token":"${TOKEN}",
  "labels": {"component":"${COMPONENT}"},
  "log_level":"DEBUG",
  "api_port":"8570",
  "route_http_port":"80",
  "route_tls_port":"443",
  "data_file":"/var/db/microagent/bolt.db"
}
END
}

microagent_update() {
  cat <<'END'
#!/bin/bash

set -e

# extract installed version
current=$(md5sum /usr/local/bin/microagent | awk '{printf $1}')

# download the latest checksum
curl \
  -f \
  -k \
  -s \
  -o /tmp/microagent.md5 \
  https://s3.amazonaws.com/tools.microbox.cloud/microagent/linux/$(arch)/microagent-v2.md5

# compare latest with installed
latest=$(cat /tmp/microagent.md5)

if [ ! "${current}" = "${latest}" ]; then
  echo "Microagent is out of date, updating to latest"

  # stop the running Microagent
  service microagent stop

  # download the latest version
  curl \
    -f \
    -k \
    -o /usr/local/bin/microagent \
    https://s3.amazonaws.com/tools.microbox.cloud/microagent/linux/$(arch)/microagent-v2

  # update permissions
  chmod 755 /usr/local/bin/microagent

  # start the new version
  service microagent start

  # move temporary md5
  mv /tmp/microagent.md5 /var/microbox/microagent.md5
else
  service microagent restart
  echo "Microagent is up to date."
fi
END
}

microagent_upstart_conf() {
  cat <<'END'
description "Microagent daemon"

oom score never

start on (filesystem and net-device-up IFACE!=lo and firewall)
stop on runlevel [!2345]

respawn

kill timeout 20

exec su root -c '/usr/local/bin/microagent server --config /etc/microagent/config.json >> /var/log/microagent.log 2>&1'
END
}

microagent_systemd_conf() {
  cat <<'END'
[Unit]
Description=Microagent daemon
After=syslog.target network.target redd.service

[Service]
User=root
OOMScoreAdjust=-1000
ExecStart=/usr/local/bin/microagent server --config /etc/microagent/config.json 2>&1
Restart=always

[Install]
WantedBy=multi-user.target
END
}

build_firewall() {
  cat <<END
#!/bin/bash

if [ ! -f /run/iptables ]; then
  # flush the current firewall
  iptables -F

  # Set default policies (nothing in, anything out)
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  # Allow returning packets
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Allow local traffic
  iptables -A INPUT -i lo -j ACCEPT

  # allow ssh connections from anywhere
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT

  # allow microagent api connections
  iptables -A INPUT -p tcp --dport 8570 -j ACCEPT

  # allow microagent ssh connections
  iptables -A INPUT -p tcp --dport 1289 -j ACCEPT

  # allow icmp packets
  iptables -A INPUT -p icmp -j ACCEPT

  # Allow vxlan and docker traffic
  iptables -A INPUT -i redd0 -j ACCEPT
  iptables -A FORWARD -i redd0 -j ACCEPT
  iptables -A FORWARD -o redd0 -j ACCEPT
  iptables -A INPUT -i docker0 -j ACCEPT
  iptables -A FORWARD -i docker0 -j ACCEPT
  iptables -A FORWARD -o docker0 -j ACCEPT
  iptables -t nat -A POSTROUTING -o ${INTERNAL_IFACE} -j MASQUERADE
END

if [ -n "${EXTERNAL_IFACE}" ]
then
  echo "  iptables -t nat -A POSTROUTING -o ${EXTERNAL_IFACE} -j MASQUERADE"
fi

cat <<END
  touch /run/iptables
fi
END
}

firewall_upstart_conf() {
  cat <<'END'
description "Microbox firewall base lockdown"

start on runlevel [2345]

emits firewall

script

/usr/local/bin/build-firewall.sh
initctl emit firewall

end script
END
}

firewall_systemd_conf() {
  cat <<'END'
[Unit]
Description=Microbox firewall base lockdown

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/build-firewall.sh

[Install]
WantedBy=multi-user.target
END
}

run() {
  echo "+> $2"
  $1 2>&1 | format '   '
}

format() {
  prefix=$1
  while read -s LINE;
  do
    echo "${prefix}${LINE}"
  done
}

# parse args and set values
for i in "${@}"; do

  case $i in
    id=* )
      ID=${i#*=}
      ;;
    token=* )
      TOKEN=${i#*=}
      ;;
    vip=* )
      VIP=${i#*=}
      ;;
    component=* )
      COMPONENT=${i#*=}
      ;;
    internal-iface=* )
      INTERNAL_IFACE=${i#*=}
      ;;
    external-iface=* )
      EXTERNAL_IFACE=${i#*=}
      ;;
  esac

done

let MTU=$(netstat -i | grep ${INTERNAL_IFACE} | awk '{print $2}')-50

# silently fix hostname in ps1
fix_ps1

run ensure_iface_naming_consistency "Making sure interfaces are named predictably"

run configure_updates "Configuring automatic updates"

run install_docker "Installing docker"
run start_docker "Starting docker daemon"

run install_red "Installing red"
run start_redd "Starting red daemon"

run install_bridgeutils "Installing ethernet bridging utilities"
run install_nfsutils "Installing nfs client utilities"
run create_docker_network "Creating isolated docker network"
run create_vxlan_bridge "Creating red vxlan bridge"
run start_vxlan_bridge "Starting red vxlan bridge"

run configure_modloader "Configuring modloader"
run start_modloader "Starting modloader"

run configure_firewall "Configuring firewall"
run start_firewall "Starting firewall"

run install_microagent "Installing microagent"
run start_microagent "Starting microagent"

echo "+> Hold on to your butts"
