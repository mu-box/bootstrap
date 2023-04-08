#!/bin/bash
#
# Boostraps a CI server to run tests or deploy an app with Microbox
#
# bash -c "$(curl -fsSL https://s3.amazonaws.com/tools.microbox.cloud/bootstrap/ci.sh)"

# run_as_root
run_as_root() {
  if [[ "$(whoami)" = "root" ]]; then
    eval "$1"
  else
    sudo bash -c "$1"
  fi
}

# run_as_user
run_as_user() {
  if [[ -n $SUDO_USER ]]; then
    su -c "$1" - $SUDO_USER
  else
    eval "$1"
  fi
}

arch() {
  dpkg --print-architecture
}

docker_defaults() {
  echo 'DOCKER_OPTS="--iptables=false --storage-driver=aufs"'
}

# 1 - Install and run docker
# 2 - Download microbox
# 3 - Chown microbox
# 4 - Set Microbox configuration

# 1 - Install Docker
#
# * For the time being this only supports an Ubuntu installation.
#   If there is reason to believe other linux distributions are commonly
#   used for CI/CD solutions, we can switch through them here

if [[ ! -f /usr/bin/docker ]]; then
  # add docker"s gpg key
  run_as_root "mkdir -m 0755 -p /etc/apt/keyrings"
  run_as_root "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"

  # ensure lsb-release is installed
  which lsb_release || run_as_root "apt-get -y install lsb-release"

  version=$(lsb_release -rs)
  release=$(lsb_release -cs)

  [ -f /usr/lib/apt/methods/https ] || run_as_root "apt-get -y install apt-transport-https"

  # add the source to our apt sources
  run_as_root "echo \
    \"deb [arch=$(arch) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${release} main\" \
      > /etc/apt/sources.list.d/docker.list"

  # update the package index
  run_as_root "apt-get -y update"

  # ensure the old repo is purged
  run_as_root "apt-get -y purge docker docker-engine docker.io containerd runc"

  # set docker defaults
  run_as_root "echo $(docker_defaults) > /etc/default/docker"

  # install docker
  run_as_root "apt-get \
      -y \
      -o Dpkg::Options::=\"--force-confdef\" \
      -o Dpkg::Options::=\"--force-confold\" \
      install \
      docker-engine=23.0.3-1~ubuntu.${version}~${release}"

  # allow user to use docker without sudo needs to be conditional
  run_as_root "groupadd docker"
  REAL_USER=${SUDO_USER:-$USER}
  run_as_root "usermod -aG docker $REAL_USER"
fi

# 2 - Download microbox
run_as_root "curl \
  -f \
  -k \
  -o /usr/local/bin/microbox \
  https://s3.amazonaws.com/tools.microbox.cloud/microbox/v2/linux/$(arch)/microbox"

# 3 - Chown microbox
run_as_root "chmod +x /usr/local/bin/microbox"

# 4 - Set microbox configuration
run_as_user "microbox config set ci-mode true"

run_as_user "microbox config set provider native"

echo "Microbox is ready to go!"
