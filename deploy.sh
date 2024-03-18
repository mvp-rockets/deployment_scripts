#!/usr/bin/env bash
set -e
# Config
if [ -z "$1" ]
then
    echo "No argument supplied"
    exit 1
fi
TYPE=$2
export Deploying_username="$( git config --get user.name )"
export Deploying_usermail="$( git config --get user.email )"
export Deployment_environment="$1"

#deploy api prod or uat
if ([ $1 == "uat" ] || [ $1 == "production" ] || [ $1 == "automation" ]) && [ "$TYPE" == "api" ];
then
    echo "npm install in app folder"
    cd ../app && npm install --force && cd ../scripts
    echo "Deploying to $1"
    export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    . "$SCRIPT_DIR/env/.env.$1"

    export PROJECT_DIR="$SCRIPT_DIR/.."
    export IDENTITY_FILE="$SCRIPT_DIR/$IDENTITY_FILE"
    export GIT_COMMIT="$(env -i git rev-parse --short HEAD)"
    export DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"
    export ROOT_DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"

    if [[ "$IDENTITY_FILE" != "" ]]; then
        export KEYARG="-i $IDENTITY_FILE"
    else
        export KEYARG=
    fi

    if [ $1 == "production" ] && [ "$TYPE" == "api" ];
    then    
        target_groups=(arn:aws:elasticloadbalancing:ap-southeast-1:) #add production target group arn here
    elif [ $1 == "uat" ] && [ "$TYPE" == "api" ];
    then 
        target_groups=(arn:aws:elasticloadbalancing:ap-southeast-1:)
    elif [ $1 == "automation" ] && [ "$TYPE" == "api" ];
    then
        target_groups=(arn:aws:elasticloadbalancing:ap-southeast-1:)
    else
        echo "please provide target group arn"
        exit 1
    fi

    for target_group in ${target_groups[@]}; do
      echo $target_group
      export AWS_EC2_TARGET_GROUP_ARN=$target_group
      . "$SCRIPT_DIR/incl.sh"
      apiHostnames=( `node ../app/get-ips-by-target-group-index.js` )
      echo "target hosts are $apiHostnames"
      for apiHostname in "${apiHostnames[@]}"
      do
        export INSTANCE_ID=$apiHostname
        log "Deploying $TYPE on $apiHostname"
        $SCRIPT_DIR/deploy-$TYPE.sh $1 $TYPE
        echo "deployment done for api on host $apiHostname"
      done
    done
#deploy api or web on qa server
elif [ $1 == "qa" ]  && ([ "$TYPE" == "api" ] || [ "$TYPE" == "web" ]);
then
    export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    . "$SCRIPT_DIR/env/.env.$1"
    export PROJECT_DIR="$SCRIPT_DIR/.."
    export IDENTITY_FILE="$SCRIPT_DIR/$IDENTITY_FILE"
    export GIT_COMMIT="$(env -i git rev-parse --short HEAD)"
    export ROOT_DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"
    if [[ "$IDENTITY_FILE" != "" ]]; then
        export KEYARG="-i $IDENTITY_FILE"
    else
        export KEYARG=
    fi
    . "$SCRIPT_DIR/incl.sh"
    echo $TYPE
    if [[ -n "$TYPE" ]]
    then
        log "Deploying $TYPE "
        $SCRIPT_DIR/deploy-$TYPE.sh $1 $TYPE
    fi
#deploy web on uat or prod server
elif ([ $1 == "production" ] || [ $1 == "uat" ] || [ $1 == "automation" ]) && [ "$TYPE" == "web" ];
then
    echo "npm install in app folder"
    cd ../app && npm install --force && cd ../scripts
    echo "Deploying to $1"
    export SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    . "$SCRIPT_DIR/env/.env.$1"

    export PROJECT_DIR="$SCRIPT_DIR/.."
    export IDENTITY_FILE="$SCRIPT_DIR/$IDENTITY_FILE"
    export GIT_COMMIT="$(env -i git rev-parse --short HEAD)"
    export DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"
    export ROOT_DEPLOYMENT_DIR="/home/$REMOTE_USER/apps/$PROJECT_NAME/$NODE_ENV"

    if [[ "$IDENTITY_FILE" != "" ]]; then
        export KEYARG="-i $IDENTITY_FILE"
    else
        export KEYARG=
    fi

    if [ $1 == "production" ] && [ "$TYPE" == "web" ];
    then    
        target_groups=(arn:aws:elasticloadbalancing:ap-southeast-1:) #add production target group arn here
    elif [ $1 == "uat" ] && [ "$TYPE" == "web" ];
    then
        target_groups=(arn:aws:elasticloadbalancing:ap-southeast-1:)
    elif [ $1 == "automation" ] && [ "$TYPE" == "web" ];
    then
        target_groups=(arn:aws:elasticloadbalancing:ap-southeast-1:)
    else
        echo "please provide target group arn"
        exit 1
    fi

    for target_group in ${target_groups[@]}; do
      echo $target_group
      export AWS_EC2_TARGET_GROUP_ARN=$target_group
      . "$SCRIPT_DIR/incl.sh"
      apiHostnames=( `node ../app/get-ips-by-target-group-index.js` )
      echo "target hosts are $apiHostnames"
      for apiHostname in "${apiHostnames[@]}"
      do
        export INSTANCE_ID=$apiHostname
        log "Deploying $TYPE on $apiHostname"
        $SCRIPT_DIR/deploy-$TYPE.sh $1 $TYPE
        echo "deployment done for $TYPE on host $apiHostname"
      done
    done
else 
    echo "please check once"
    exit 1
fi
#. "$SCRIPT_DIR/incl.sh"

#echo $TYPE
#if [[ -n "$TYPE" ]]
#then
#    log "Deploying $TYPE"
#    $SCRIPT_DIR/deploy-$TYPE.sh
#else
#    log "Deploying all aps"
#    $SCRIPT_DIR/deploy-api.sh
#    $SCRIPT_DIR/deploy-web.sh
#fi
