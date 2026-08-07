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
sudo find "$DESTINATION" -type d -exec chmod 755 {} +
sudo find "$DESTINATION" -type f -exec chmod 644 {} +
sudo chown -R www-data:www-data "$DESTINATION"

echo "✅ Deployment completed successfully!"
