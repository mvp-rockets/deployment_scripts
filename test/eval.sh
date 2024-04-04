#!/usr/bin/env bash
set -e

target=$(echo "$1" | tr '[:lower:]' '[:upper:]')

export TARGET_UI="UI"
export TARGET_API="API"
export TARGET_ADMIN="ADMIN"
export TARGET_FLUTTER="Flutter"

var="TARGET_"$(echo "$1" | tr '[:lower:]' '[:upper:]')
echo "${!var}"
ele="ELEMENT_"$(echo "$1" | tr '[:lower:]' '[:upper:]')
export ${!var}

echo "$ELEMENT_UI"

if [[ -n ${!var} ]]
then
  echo "Var has value"
fi
if [[ -z ${!var} ]]
then
  echo "Var is empty"
fi

if [[ ${!var} == "UI" ]]
then
  echo "Var == UI"
fi

if [[ ! -d "../../apis/node_modules" && -n ${!var} ]]; then
  echo "No node_modules present & $var has value"
fi

if [[ $(node -v) != $(cat ../.nvmrc) ]]; then
  echo "Node mistmach"
else
  echo "Node $(node -v)"
fi
