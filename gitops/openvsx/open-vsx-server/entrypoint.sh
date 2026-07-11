#!/bin/bash

set -e
set -o pipefail

# start openvsx
pushd /openvsx-server || return
./run-server.sh &
printf "Waiting until openvsx is ready"
timeout 0 bash -c "until curl --output /dev/null --head --silent --fail http://localhost:8080/user; do printf '.'; sleep 1; done"
printf "Openvsx is ready"
tail -f /dev/null
