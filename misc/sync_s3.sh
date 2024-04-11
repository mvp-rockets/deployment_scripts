#!/usr/bin/env bash

if [ -z "$1" ]
  then
    echo "Which s3 directory you want to sync? dev, qa or prod"
    exit 1
fi
echo syncing to [[[ $1 ]]] s3 directory

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
export PROJECT_DIR="$SCRIPT_DIR/.."

echo "$(s3cmd --version)"
echo "Environment is $1"
s3cmd --acl-public sync $PROJECT_DIR/ui/public/ --add-header="Cache-Control:max-age=86400"  s3://$BUCKET_NAME/ui/
s3cmd --acl-public sync $PROJECT_DIR/admin/public/ --add-header="Cache-Control:max-age=86400"  s3://$BUCKET_NAME/admin/
