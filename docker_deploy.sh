#!/bin/bash
#
# Docker zero-downtime deployment script.

set -eo pipefail

main() {

declare -r PRIVATE_DOCKER_REGISTRY="registry.devops101.com"
declare -r arg="$@"

_lock_script
trap _exit_trap EXIT
trap _err_trap ERR
_showed_traceback=f
pre_deploy_checks
pull_app_docker_image
pull_nginx_docker_image
start_nginx_container  
get_old_app_container_id
start_new_app_container && countdown "${@:-60}"
post_deploy_checks || kill_new_container
stop_old_app_container
cleanup_old_app_container

}

pre_deploy_checks() {
  echo '>>> Running pre_deploy_checks...'

  #check environment variables
  : ${GIT_COMMIT_ID:?'GIT_COMMIT_ID is undefined.'}
  : ${APP_NAME:?'APP_NAME is undefined. '}
  
  #check docker is installed
  type docker >/dev/null 2>&1 || \
  { 
    echo >&2 "error: docker is not installed. Aborting." && exit 1
  }

  #check privileges
  DOCKER='docker'
  (( EUID == 0 )) || DOCKER='sudo docker'

  #parse argument
  local re='^[0-9]+$'
  echo $arg
  if ! [[ "$arg" =~ $re ]]; then
    echo "error: The passed countdown argument is not a number." >&2
    exit 1
  fi

  #check private registry is available
  CURL_OPTIONS="-q --compressed --fail --location --max-time 30"
  local REGISTRY_URL="https://$PRIVATE_DOCKER_REGISTRY/_ping"
  if ! [[ $(curl $CURL_OPTIONS $REGISTRY_URL) =~ true ]]; then 
    echo "cannot reach $PRIVATE_DOCKER_REGISTRY."
    exit 1
  fi

}

pull_app_docker_image() {
  echo ">>>Pulling $PRIVATE_DOCKER_REGISTRY/$APP_NAME:$GIT_COMMIT_ID from private registry"
  $DOCKER pull $PRIVATE_DOCKER_REGISTRY/$APP_NAME:$GIT_COMMIT_ID
}

pull_nginx_docker_image() {
  echo '>>>Pulling nginx container'
  $DOCKER pull $PRIVATE_DOCKER_REGISTRY/nginx-$APP_NAME
}

start_nginx_container() {
  echo '>>> Ensuring nginx container is running'
  [[ $($DOCKER ps) =~ 80-\>80 ]] || $DOCKER run -d -p 80:80 \
  -v /var/run/docker.sock:/tmp/docker.sock \
  -v /var/log/nginx:/var/log/nginx $PRIVATE_DOCKER_REGISTRY/nginx-$APP_NAME
}

get_old_app_container_id() {
  echo '>>> Get old container id'
  CID=$( $DOCKER ps | awk '/my_init/ {print $1}') \
  || echo "$APP_NAME container is not currently running"
  echo $CID
}

start_new_app_container() {
  echo '>>> Starting new container'
  NEW_APP_CONTAINER_ID=$($DOCKER run -d --env-file=/etc/docker_env \
  -v /var/log/wsgi:/var/log/wsgi -v /var/log/nginx:/var/log/nginx \
  $PRIVATE_DOCKER_REGISTRY/$APP_NAME:$GIT_COMMIT_ID) && echo $NEW_APP_CONTAINER_ID
}

post_deploy_checks() {
  echo '>>> Running status checks on the new container...'
  local NEW_CONTAINER_IPADDRESS=$(ip_address_of $NEW_APP_CONTAINER_ID)
  [[ $(curl -sL -w "%{http_code}\n" "http://$NEW_CONTAINER_IPADDRESS" -o /dev/null) =~ 200 ]] \
  || [[ $(curl -sL -w "%{http_code}\n" "http://$NEW_CONTAINER_IPADDRESS/admin" -o /dev/null) =~ 200 ]] \
  && echo "The Application started Succesfully."
}

stop_old_app_container() {
  echo '>>> Stopping old container'
  [[ -z "$CID" ]] || $DOCKER stop $CID
}    
  
cleanup_old_app_container() {
  echo '>>> Cleaning up containers'
  # delete all non-running containers
  $DOCKER rm <($DOCKER ps -a | awk '/Exit/ {print $1}')
}
 
countdown() {
  local seconds="$@"
  while [ $seconds -gt 0 ]; do
  echo -ne "The new $APP_NAME container post-deploy checks will start in $seconds\033[0K seconds\r"
  sleep 1
  : $((seconds--))
  done
}

ip_address_of() {
  exec $DOCKER inspect --format '{{ .NetworkSettings.IPAddress }}' "$@" \
  || { 
       echo >&2 "could not get the ip address of $@ ." && exit 1 
     } 
}

kill_new_container() {
  echo "error: The Application running on the new container $NEW_APP_CONTAINER_ID failed to respond. \
  Shooting the new container on the head now... " >&2  \
  $DOCKER kill $NEW_APP_CONTAINER_ID && echo "$NEW_APP_CONTAINER_ID killed succesfully."
  exit 2
}

_exit_trap() {
  local _ec="$?"
  if [[ $_ec != 0 && "${_showed_traceback}" != t ]]; then
    traceback 1
  fi
}
 
_err_trap() {
  local _ec="$?"
  local _cmd="${BASH_COMMAND:-unknown}"
  traceback 1
  _showed_traceback=t
  echo "The command ${_cmd} exited with exit code ${_ec}." 1>&2
}

traceback() {
  # Hide the traceback() call.
  local -i start=$(( ${1:-0} + 1 ))
  local -i end=${#BASH_SOURCE[@]}
  local -i i=0
  local -i j=0

  echo "Traceback (last called is first):" 1>&2
  for ((i=${start}; i < ${end}; i++)); do
    j=$(( $i - 1 ))
    local function="${FUNCNAME[$i]}"
    local file="${BASH_SOURCE[$i]}"
    local line="${BASH_LINENO[$j]}"
    echo "     ${function}() in ${file}:${line}" 1>&2
  done
}

_lock_script() {
  #Ensure only one instance of the script is running. 
  local LOCKFILE="/tmp/docker_deploy"
  if ( set -o noclobber; echo "$$" > "$LOCKFILE") 2> /dev/null; then
    trap 'rm -f "$LOCKFILE"; exit $?' INT TERM EXIT
    echo "Locking succeeded" >&2
    rm -f "$LOCKFILE"
  else
    echo "Lock failed - exiting script" >&2
    exit 1
  fi
}

main "$@"
