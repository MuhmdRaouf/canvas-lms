#!/bin/bash

set -e

source build/common_docker_build_steps.sh

# shellcheck disable=1004
echo '
  ________  ________  ________   ___      ___ ________  ________
|\   ____\|\   __  \|\   ___  \|\  \    /  /|\   __  \|\   ____\
\ \  \___|\ \  \|\  \ \  \\ \  \ \  \  /  / | \  \|\  \ \  \___|_
 \ \  \    \ \   __  \ \  \\ \  \ \  \/  / / \ \   __  \ \_____  \
  \ \  \____\ \  \ \  \ \  \\ \  \ \    / /   \ \  \ \  \|____|\  \
   \ \_______\ \__\ \__\ \__\\ \__\ \__/ /     \ \__\ \__\____\_\  \
    \|_______|\|__|\|__|\|__| \|__|\|__|/       \|__|\|__|\_________\
                                                         \|_________|

Welcome! This script will guide you through the process of setting up a
Canvas development environment with docker and dinghy/dory.

When you git pull new changes, you can run ./scripts/docker_dev_update.sh
to bring everything up to date.'

if [[ "$USER" == 'root' ]]; then
  echo 'Please do not run this script as root!'
  echo "I'll ask for your sudo password if I need it."
  exit 1
fi

OS="$(uname)"

# Defaults
DINGHY_MEMORY='8192'
DINGHY_CPUS='4'
DINGHY_DISK='150'
# docker-compose version 1.20.0 introduced build-arg that we use for linux
DOCKER_COMPOSE_MIN_VERSION='1.20.0'

function installed {
  type "$@" &> /dev/null
}

if [[ $OS == 'Darwin' ]]; then
  install='brew install'
  #docker-compose is checked separately
  dependencies='docker docker-machine dinghy'
elif [[ $OS == 'Linux' ]] && ! installed apt-get; then
  echo 'This script only supports Debian-based Linux'
  exit 1
elif [[ $OS == 'Linux' ]]; then
  #when more dependencies get added, modify Linux install output below
  #docker-compose is checked separately
  dependencies='dory'
else
  echo 'This script only supports MacOS and Linux :('
  exit 1
fi

function check_dependencies {
  #check for proper docker-compose version
  if ! check_docker_compose_version; then
    message "docker-compose $DOCKER_COMPOSE_MIN_VERSION or higher is required."
    printf "\tPlease see %s for installation instructions.\n" "https://docs.docker.com/compose/install/"
  fi
  #check for required packages installed
  local packages=()
  for package in $dependencies; do
    if ! installed "$package"; then
      packages+=("$package")
    fi
  done
  #if missing packages, print missing packages with install assistance.
  if [[ ${#packages[@]} -gt 0 ]]; then
    message "Some additional dependencies need to be installed for your OS."
    printf -v joined '%s,' "${packages[@]}"
    echo "Please install ${joined%,}."
    #when more dependencies get added, modify this output to include them.
    if [[ $OS == 'Linux' ]];then
      if [[ "${packages[*]}" =~ "dory" ]];then
        printf "\tTry: gem install dory\n"
      fi
    elif [[ $OS == 'Darwin' ]];then
      printf "\tTry: %s %s\n" "$install" "${packages[*]}"
    else
      echo 'This script only supports MacOS and Linux :('
      exit 1
    fi
    printf "\nOnce all dependencies are installed, rerun this script.\n"
    exit 1
  fi
}

function check_docker_compose_version {
  if ! installed "docker-compose"; then
    return 1
  fi
  compose_version=$(eval docker-compose --version |grep -oE "[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+")
  if (( $(echo "$compose_version $DOCKER_COMPOSE_MIN_VERSION" | awk '{print ($1 < $2)}') )); then
    return 1
  fi
}

function create_dinghy_vm {
  if ! dinghy status | grep -q 'not created'; then
    existing_memory="$(docker-machine inspect --format "{{.Driver.Memory}}" "${DOCKER_MACHINE_NAME}")"
    if [[ "$existing_memory" -lt "$DINGHY_MEMORY" ]]; then
      echo "
  Canvas requires at least 8GB of memory dedicated to the VM. Please recreate
  your VM with a memory value of at least ${DINGHY_MEMORY}. For Example:

      $ dinghy create --memory ${DINGHY_MEMORY}"
      exit 1
    else
      message "Using existing dinghy VM..."
      return 0
    fi
  fi

  prompt 'OK to create a dinghy VM? [y/n]' confirm
  [[ ${confirm:-n} == 'y' ]] || return 1

  if ! installed VBoxManage; then
    message 'Please install VirtualBox first!'
    return 1
  fi

  prompt "How much memory should I allocate to the VM (in MB)? [$DINGHY_MEMORY]" memory
  prompt "How many CPUs should I allocate to the VM? [$DINGHY_CPUS]" cpus
  prompt "How big should the VM's disk be (in GB)? [$DINGHY_DISK]" disk

  message "OK let's do this."
  dinghy create \
    --provider=virtualbox \
    --memory "${memory:-$DINGHY_MEMORY}" \
    --cpus "${cpus:-$DINGHY_CPUS}" \
    --disk "${disk:-$DINGHY_DISK}000"
}

function start_dinghy_vm {
  if dinghy status | grep -q 'stopped'; then
    dinghy up
  else
    message 'Looks like the dinghy VM is already running. Moving on...'
  fi
  eval "$(dinghy env)"
}

function start_docker_daemon {
  service docker status &> /dev/null && return 0
  prompt 'The docker daemon is not running. Start it? [y/n]' confirm
  [[ ${confirm:-n} == 'y' ]] || return 1
  sudo service docker start
  sleep 1 # wait for docker daemon to start
}

function setup_docker_as_nonroot {
  docker ps &> /dev/null && return 0
  message 'Setting up docker for nonroot user...'

  if ! id -Gn "$USER" | grep -q '\bdocker\b'; then
    message "Adding $USER user to docker group..."
    confirm_command "sudo usermod -aG docker $USER" || true
  fi

  message 'We need to login again to apply that change.'
  confirm_command "exec sg docker -c $0"
}

function start_dory {
  message 'Starting dory...'
  if dory status | grep -q 'not running'; then
    confirm_command 'dory up'
  else
    message 'Looks like dory is already running. Moving on...'
  fi
}

function setup_docker_environment {
  check_dependencies
  if [[ $OS == 'Darwin' ]]; then
    message "It looks like you're using a Mac. You'll need a dinghy VM. Let's set that up."
    create_dinghy_vm
    start_dinghy_vm
  elif [[ $OS == 'Linux' ]]; then
    message "It looks like you're using Linux. You'll need dory. Let's set that up."
    start_docker_daemon
    setup_docker_as_nonroot
    start_dory
  fi
  if [ -f ".env" ]; then
    message ".env exists, skipping copy of default environment variables from .env.example"
  else
    message "Copying default environment variables from docker-compose/.env.example to .env"
    cp docker-compose/.env.example .env
  fi
  if [ -f "docker-compose.override.yml" ]; then
    message "docker-compose.override.yml exists, skipping copy of default configuration"
  else
    message "Copying default configuration from config/docker-compose.override.yml.example to docker-compose.override.yml"
    cp config/docker-compose.override.yml.example docker-compose.override.yml
  fi
  echo -n "COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml" > .env
}

function copy_docker_config {
  message 'Copying Canvas docker configuration...'
  # Only copy yamls, not contents of new-jenkins folder
  confirm_command 'cp docker-compose/config/*.yml config/' || true
}

function setup_canvas {
  message 'Now we can set up Canvas!'
  copy_docker_config
  build_images
  check_gemfile
  build_assets
  create_db
}

function display_next_steps {
  message "You're good to go! Next steps:"

  # shellcheck disable=SC2016
  [[ $OS == 'Darwin' ]] && echo '
  First, run:

    eval "$(dinghy env)"

  This will set up environment variables for docker to work with the dinghy VM.'

  [[ $OS == 'Linux' ]] && echo '
  I have added your user to the docker group so you can run docker commands
  without sudo. Note that this has security implications:

  https://docs.docker.com/engine/installation/linux/linux-postinstall/

  You may need to logout and login again for this to take effect.'

  echo "
  Running Canvas:

    docker-compose up -d
    open http://canvas.docker

  Running the tests:

    docker-compose run --rm web bundle exec rspec

   Running Selenium tests:

    add docker-compose/selenium.override.yml in the .env file
      echo ':docker-compose/selenium.override.yml' >> .env

    build the selenium container
      docker-compose build selenium-chrome

    run selenium
      docker-compose run --rm web bundle exec rspec spec/selenium

    Virtual network remote desktop sharing to selenium container
      for Firefox:
        $ open vnc://secret:secret@seleniumff.docker
      for chrome:
        $ open vnc://secret:secret@seleniumch.docker:5901

  I'm stuck. Where can I go for help?

    FAQ:           https://github.com/instructure/canvas-lms/wiki/FAQ
    Dev & Friends: http://instructure.github.io/
    Canvas Guides: https://guides.instructure.com/
    Vimeo channel: https://vimeo.com/canvaslms
    API docs:      https://canvas.instructure.com/doc/api/index.html
    Mailing list:  http://groups.google.com/group/canvas-lms-users
    IRC:           http://webchat.freenode.net/?channels=canvas-lms

    Please do not open a GitHub issue until you have tried asking for help on
    the mailing list or IRC - GitHub issues are for verified bugs only.
    Thanks and good luck!
  "
}

setup_docker_environment
setup_canvas
display_next_steps
