#!/bin/bash
set -e

set -a
source .env.deploy set
set +a

DESTINATION=/var/www/$PROJECT_NAME-$APP_ENV-$DEPLOY_SERVICE
echo "🚀 Starting deployment..."
echo "📂 Source: ./dist"
echo "📁 Destination: /var/www/$DEST"

# Sync files (best practice)
echo "📦 Syncing files..."
sudo rsync -av --delete "./dist/" "$DESTINATION/"

# Set permissions (optional)
echo "🔐 Setting permissions..."
sudo chown -R www-data:www-data "$DESTINATION"
sudo chmod -R 755 "$DESTINATION"

echo "✅ Deployment completed successfully!"
