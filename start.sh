#! /bin/sh
if [ $# != 1 ]; then
  echo "USAGE: PID"
  exit 1
fi
PID=$1
ADDR=$(gdb -p $PID -ex "p (long)luaH_resize" --batch | grep "1 = " | awk '{print $3}')
if [ $? -ne 0 ]; then
  echo "$PID get luaH_resize addr fail"
  exit 1
fi
echo "ADDR="$ADDR
./hookso replacep $PID $ADDR ./libwlua.so new_luaH_resize
if [ $? -ne 0 ]; then
  echo "$PID hook luaH_resize fail"
  exit 1
fi
