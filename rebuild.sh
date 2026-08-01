#!/bin/bash

set -a
source "$(dirname "$0")/topic.env"
set +a

./refresh-board-es.sh

#PARALLEL_BUILD=y make x86_64-focused-build && ./update-usb.sh --auto
make x86_64-focused-build
EC=$?

if [ $EC -eq 0 ]; then
    ./post-build-clean.sh
    curl -H "Title: 🕹️ Batocera finished building" -d "Image building finished" $NOTIFYTOPIC
else
    curl -H "Title: 🕹️ Batocera build failed 😞" -d "Exit code $EC" $NOTIFYTOPIC
fi
