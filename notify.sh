set -a
source "$(dirname "$0")/topic.env"
set +a

if [ $1 -eq 0 ]; then
    curl -H "Title: 🕹️ Batocera finished building" -d "Image building finished" $NOTIFYTOPIC
else
    curl -H "Title: 🕹️ Batocera build failed 😞" -d "Exit code $?" $NOTIFYTOPIC
fi
