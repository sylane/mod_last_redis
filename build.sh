#!/bin/bash

ROOT=$(cd $(dirname $0); pwd)
EJABBERD_ROOT=${EJABBERD_ROOT:-"/usr/lib/ejabberd"}

mkdir -p "$ROOT/ebin" 

ERLC_PARAMS=( \ 
  -Wall \
  -I $EJABBERD_ROOT/include
  -pa $EJABBERD_ROOT/ebin
  -o $ROOT/ebin )

erlc ${ERLC_PARAMS[*]} $ROOT/src/*.erl
