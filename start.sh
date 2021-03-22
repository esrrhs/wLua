#! /bin/sh
if [ $# != 1 ]; then
  echo "USAGE: PID"
  exit 1
fi
PID=$1

#FUNC="luaH_resize luaH_get luaH_set"
FUNC="luaH_get"

for i in $FUNC; do
  ADDR=$(gdb -p $PID -ex "p (long)$i" --batch | grep "1 = " | awk '{print $3}')
  if [ $? -ne 0 ]; then
    echo "$PID get $i addr fail"
    exit 1
  fi
  echo $i" ADDR="$ADDR
  ./hookso replacep $PID $ADDR ./libwlua.so new_$i
  if [ $? -ne 0 ]; then
    echo "$PID hook $i fail"
    exit 1
  fi
done
