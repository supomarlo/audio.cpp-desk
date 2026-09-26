@echo off
setlocal
rem Build audio2wav with MinGW-w64 gcc (Media Foundation, no third-party libs).
rem Requires gcc on PATH; you may also set the GCC env var to a compiler path.
set HERE=%~dp0
if not defined GCC set GCC=gcc
if not exist "%GCC%" (
  where %GCC% >nul 2>&1
  if errorlevel 1 (
    echo [audio2wav] gcc not found: put gcc on PATH or set GCC to its full path.
    exit /b 1
  )
)
"%GCC%" -O2 -s -static -municode -o "%HERE%audio2wav.exe" "%HERE%audio2wav.c" -lmfplat -lmfreadwrite -lmfuuid -lole32 -luuid -lshlwapi
if errorlevel 1 (
  echo [audio2wav] build failed.
  exit /b 1
)
echo [audio2wav] done: %HERE%audio2wav.exe
endlocal
