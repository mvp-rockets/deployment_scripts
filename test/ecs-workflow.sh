STACK_NAME=aws_ecs
REPOSITORY_NAME='localstack-repo'

# Create a repo
repo_details=$(awslocal ecr create-repository --repository-name $STACK_NAME)
# Repo url
REPOSITORY_URI=$(echo "$repo_details" | jq -r '.repository.repositoryUri')
# Build docker image
docker build -t $REPOSITORY_URI -f api.Dockerfile
docker push $REPOSITORY_URI
docker rmi $REPOSITORY_URI

awslocal cloudformation create-stack --stack-name infra --template-body file://templates/ecs.infra.yml
awslocal cloudformation wait stack-create-complete --stack-name infra

awslocal cloudformation create-stack --stack-name $STACK_NAME --template-body file://templates/ecs.sample.yml --parameters ParameterKey=ImageUrl,ParameterValue=$REPOSITORY_URI
awslocal cloudformation wait stack-create-complete --stack-name $STACK_NAME

CLUSTER_ARN=$(awslocal ecs list-clusters | jq -r '.clusterArns[0]')
TASK_ARN=$(awslocal ecs list-tasks --cluster $CLUSTER_ARN | jq -r '.taskArns[0]')
awslocal ecs describe-tasks --cluster $CLUSTER_ARN --tasks $TASK_ARN | jq -r '.tasks[0].containers[0].networkBindings[0].hostPort'

curl localhost:45139


https://github.com/localstack-samples/localstack-pro-samples/blob/master/ec2-docker-instances/run.sh
https://github.com/localstack-samples/localstack-pro-samples/tree/master/ecs-ecr-container-app

https://github.com/awslabs/aws-cloudformation-templates/blob/master/aws/services/ECS/FargateLaunchType/clusters/public-vpc.yml
https://docs.localstack.cloud/tutorials/elb-load-balancing/
