#!/bin/bash
set -e

set -a
source .env.deploy set
set +a

DESTINATION=/var/www/$PROJECT_NAME-$APP_ENV-$DEPLOY_SERVICE
echo "🚀 Starting deployment..."
echo "📂 Source: ./dist"
echo "📁 Destination: /var/www/$DEST"

# This will work only if current deployment user has permission on $DESTINATION
# For e.g.
#sudo mkdir -p /var/www/$DESTINATION
#sudo chown -R deploy:deploy /var/www/$DESTINATION
#sudo chmod 755 /var/www/$DESTINATION

echo "📦 Syncing files..."
rsync -aq --delete --chmod=D755,F644 "./dist/" "$DESTINATION/"

echo "✅ Deployment completed successfully!"
