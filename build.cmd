@echo off
REM ===========================================================================
REM build.cmd — сборка и запуск smoke-теста из cmd.exe.
REM Запуск: двойной клик по файлу или "build.cmd" в консоли.
REM Пути относительные от папки скрипта — проект можно переносить.
REM ===========================================================================
setlocal
chcp 65001 >nul

set "PROJ=%~dp0"
set "STUDIO=C:\Program Files (x86)\Embarcadero\Studio\37.0"

"%STUDIO%\bin64\dcc64.exe" -B -Q ^
  -E"%PROJ%bin" -N0"%PROJ%bin\dcu" ^
  -U"%PROJ%Source\Data;%STUDIO%\lib\Win64\release" ^
  "%PROJ%smoke.dpr"
if errorlevel 1 (
  echo.
  echo СБОРКА УПАЛА, запуск пропускаю
  exit /b 1
)

echo.
echo === ЗАПУСК ===
set "PATH=%STUDIO%\bin64;%PATH%"
"%PROJ%bin\smoke.exe"
