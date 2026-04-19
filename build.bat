@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"

echo Building flux-desktop...
cargo build --release --package flux-desktop
if %ERRORLEVEL% NEQ 0 (
    echo Build failed.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo Copying executable to flux.scr...
copy /Y "target\release\flux-desktop.exe" "flux.scr"
if %ERRORLEVEL% NEQ 0 (
    echo Copy failed.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo Success! flux.scr has been created.
endlocal
