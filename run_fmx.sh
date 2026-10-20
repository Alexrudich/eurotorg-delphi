#!/bin/bash
# Запуск Warehouse.exe: PATH с BPL из bin64 IDE + фоновый старт.
STUDIO='C:\Program Files (x86)\Embarcadero\Studio\37.0'
EXE='D:\AI\Koda Projects\eurotorg-delphi\bin\Warehouse.exe'
export PATH="$STUDIO/bin64:$PATH"
"$EXE" &
APP_PID=$!
echo "Warehouse.exe запущен, PID=$APP_PID"
sleep 6
if kill -0 $APP_PID 2>/dev/null; then
  echo "STATUS: работает (окно открыто)"
else
  wait $APP_PID
  echo "STATUS: завершился, код=$?"
fi