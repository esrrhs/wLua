#! /bin/sh
if [ $# != 1 ]; then
  echo "USAGE: PID"
  exit 1
fi
PID=$1

rm wlua_result.log -rf

./hookso dlopen $PID ./libwlua.so
if [ $? -ne 0 ]; then
  echo "$PID dlopen libwlua.so fail"
  exit 1
fi

ADDR=$(gdb -p $PID -ex "p (long)&luaO_nilobject_" --batch | grep "1 = " | awk '{print $3}')
if [ $? -ne 0 ]; then
  echo "$PID get luaO_nilobject_ addr fail"
  exit 1
fi
echo "set_lua_nilobject ADDR="$ADDR
./hookso call $PID libwlua.so set_lua_nilobject i=$ADDR
if [ $? -ne 0 ]; then
  echo "$PID call set_lua_nilobject fail"
  exit 1
fi

FUNC="luaH_resize luaH_get luaH_set luaC_fullgc luaC_step luaC_newobj"

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
