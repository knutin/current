#!/bin/bash
cd $(dirname $0)
pkill -9 -f DynamoDBLocal || true
java -Djava.library.path=../dynamodb_local/DynamoDBLocal_lib -jar ../dynamodb_local/DynamoDBLocal.jar -inMemory 1>/dev/null 2&>1 &
echo '==> local dynamo (started)'
exit 0
