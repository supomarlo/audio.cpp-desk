@echo off
setlocal
set ROOT=%~dp0
for /f "tokens=2 delims=: " %%v in ('findstr /b "version:" "%ROOT%app\pubspec.yaml"') do set VER=%%v
echo [package] version = %VER%

taskkill /IM audio_cpp_desk.exe /F >nul 2>&1

rem optional detailed build output:  package_release.bat -v
set "FLUTTER_VERBOSE="
if /i "%~1"=="-v" set "FLUTTER_VERBOSE=-v"
if /i "%~1"=="--verbose" set "FLUTTER_VERBOSE=-v"
if /i "%~1"=="verbose" set "FLUTTER_VERBOSE=-v"

rem build timeout in seconds (override with: set PKG_BUILD_TIMEOUT=3600)
set "BUILD_TIMEOUT=%PKG_BUILD_TIMEOUT%"
if not defined BUILD_TIMEOUT set "BUILD_TIMEOUT=1200"

rem the Windows build may need nuget.exe (audioplayers/dependency); the plugin's
rem download has no timeout, so on restricted networks it can hang forever.
if not exist "%ROOT%app\build\windows\x64\_deps\nuget-src\nuget.exe" (
  where nuget >nul 2>&1 || echo [package] note: NuGet is not on PATH; the build will try to download nuget.exe from dist.nuget.org and may hang. Install nuget and add it to PATH to skip the download.
)

echo [package] building windows release ... (timeout %BUILD_TIMEOUT%s %FLUTTER_VERBOSE%)
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $to=[int]%BUILD_TIMEOUT%; $p=Start-Process -FilePath cmd.exe -ArgumentList '/c','flutter build windows --release %FLUTTER_VERBOSE%' -WorkingDirectory '%ROOT%app' -NoNewWindow -PassThru; $el=0; while (-not $p.WaitForExit(5000)) { $el+=5; if ($el -ge $to) { Write-Host ''; Write-Host '[package] ERROR: build timed out - likely a stalled NuGet/network download (dist.nuget.org).'; taskkill /PID $p.Id /T /F | Out-Null; exit 124 }; if (($el %% 60) -eq 0) { Write-Host ('[package] still building... ' + $el + 's') } }; exit $p.ExitCode }"
if errorlevel 1 (
  echo [package] build failed.
  exit /b 1
)
echo [A]

set REL=%ROOT%app\build\windows\x64\runner\Release
if not exist "%REL%\audio_cpp_desk.exe" (
  echo [package] executable not found.
  exit /b 1
)

for %%d in (audio.cpp models) do if exist "%REL%\%%d" rmdir /s /q "%REL%\%%d"
for %%d in (download history logs model_specs run uploads voices) do if exist "%REL%\data\%%d" rmdir /s /q "%REL%\data\%%d"
del "%REL%\data\config.json" "%REL%\data\model_catalog.json" >nul 2>&1
echo [B]

set PKG=%ROOT%dist\audio_cpp_desk-%VER%
if exist "%PKG%" rmdir /s /q "%PKG%"
mkdir "%PKG%\bin"
xcopy "%REL%\*" "%PKG%\bin" /e /i /y >nul
echo [C]

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo [package] csc.exe not found.
  exit /b 1
)
"%CSC%" /nologo /target:winexe /out:"%PKG%\audio.cpp Desk.exe" /win32icon:"%ROOT%app\windows\runner\resources\app_icon.ico" "%ROOT%windows_launcher\launcher.cs"
echo [D]
if errorlevel 1 (
  echo [package] launcher compile failed.
  exit /b 1
)

rem license copy inside bin/
if not exist "%PKG%\bin\licenses" mkdir "%PKG%\bin\licenses"
copy /y "%ROOT%app\assets\licenses\audio.cpp-LICENSE.txt" "%PKG%\bin\licenses\audio.cpp-LICENSE.txt" >nul

rem project LICENSE / NOTICE inside bin/licenses (root of the release repo;
rem when packaging from the dev tree they live under github\)
set "DOCDIR=%ROOT%"
if not exist "%DOCDIR%LICENSE" if exist "%ROOT%github\LICENSE" set "DOCDIR=%ROOT%github\"
for %%f in (LICENSE NOTICE) do (
  if exist "%DOCDIR%%%f" (
    copy /y "%DOCDIR%%%f" "%PKG%\bin\licenses\%%f" >nul
  ) else (
    echo [package] warning: %%f not found; not included in bin\licenses
  )
)

rem bundle the MSVC runtime app-locally (so no VC++ Redistributable is required)
set "VCRT_DIR="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSINST="
if exist "%VSWHERE%" for /f "usebackq delims=" %%p in (`"%VSWHERE%" -latest -products * -property installationPath 2^>nul`) do set "VSINST=%%p"
if defined VSINST for /f "delims=" %%d in ('dir /b /ad /o-n "%VSINST%\VC\Redist\MSVC\*" 2^>nul') do (
  if not defined VCRT_DIR for /d %%c in ("%VSINST%\VC\Redist\MSVC\%%d\x64\Microsoft.VC*.CRT") do (
    if exist "%%c\vcruntime140.dll" set "VCRT_DIR=%%c"
  )
)
if defined VCRT_DIR (
  for %%f in (msvcp140.dll msvcp140_1.dll msvcp140_2.dll vcruntime140.dll vcruntime140_1.dll concrt140.dll) do if exist "%VCRT_DIR%\%%f" copy /y "%VCRT_DIR%\%%f" "%PKG%\bin\%%f" >nul
  echo [package] bundled MSVC runtime from "%VCRT_DIR%"
) else (
  echo [package] warning: MSVC runtime redist not found; target machines may need the VC++ Redistributable.
)

rem bundled audio transcoder (our own, Media Foundation based; no third-party)
if exist "%ROOT%tools\audio2wav\audio2wav.exe" (
  copy /y "%ROOT%tools\audio2wav\audio2wav.exe" "%PKG%\bin\audio2wav.exe" >nul
) else (
  echo [package] warning: tools\audio2wav\audio2wav.exe missing; run tools\audio2wav\build.bat
)

if not exist "%ROOT%dist" mkdir "%ROOT%dist"
set OUT=%ROOT%dist\audio_cpp_desk-%VER%-windows-x64.zip
if exist "%OUT%" del "%OUT%"
powershell -NoProfile -Command "Compress-Archive -Path '%PKG%\*' -DestinationPath '%OUT%' -Force"
echo [package] done: %OUT%
endlocal
