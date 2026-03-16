@echo off
:: ============================================================================
:: build_socketio.bat - Compila o sample SocketIOServer
:: ============================================================================
set CONFIG=%1
if "%CONFIG%"=="" set CONFIG=Debug

call "C:\Program Files (x86)\Embarcadero\Studio\21.0\bin\rsvars.bat"

set PROJ_ROOT=..\..
set SRC=%PROJ_ROOT%\src
set HORSE=%PROJ_ROOT%\vendor\horse\src
set WS_LIB=%PROJ_ROOT%\vendor\websocket.pas
set SYNAPSE=%PROJ_ROOT%\vendor\synapse

set SEARCH_PATH=%SRC%;%HORSE%;%WS_LIB%;%SYNAPSE%

if not exist bin\%CONFIG% mkdir bin\%CONFIG%
if not exist dcu\%CONFIG% mkdir dcu\%CONFIG%

echo.
echo === Compilando SocketIOServer [%CONFIG%] ===
echo.

DCC32.EXE SocketIOServer.dpr ^
  -U"%SEARCH_PATH%" ^
  -I"%SEARCH_PATH%" ^
  -E"bin\%CONFIG%" ^
  -N"dcu\%CONFIG%"

if %ERRORLEVEL% == 0 (
  echo.
  echo *** BUILD OK! ***
  echo Executavel: samples\socketio\bin\%CONFIG%\SocketIOServer.exe
) else (
  echo.
  echo *** BUILD FALHOU! ***
)
