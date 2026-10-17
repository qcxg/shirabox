@echo off
setlocal EnableExtensions EnableDelayedExpansion
pushd "%~dp0"

rem Tool lookup order:
rem   Java: JAVA_HOME, legacy JAVA_BIN, Android Studio JBR, then PATH.
rem   SDK:  ANDROID_SDK_ROOT, legacy ANDROID_HOME, then %%LOCALAPPDATA%%\Android\Sdk.
rem Optional overrides: ANDROID_JAR points at android.jar and BUILD_TOOLS points
rem at a build-tools directory containing d8.bat.

set "OUTPUT_JAR=%~dp0build\server.jar"
set "ASSET_JAR=%~dp0..\assets\server.jar"
set "BUILD_DIR=%~dp0_build"
set "CLASSES_DIR=!BUILD_DIR!\classes"
set "DEX_DIR=!BUILD_DIR!\dex"
set "STAGED_JAR=!BUILD_DIR!\server.jar"
set "JAVAC="
set "JAR_TOOL="
set "D8="
set "SDK_ROOT="

call :find_java
if errorlevel 1 goto :fail
call :find_android_sdk
if errorlevel 1 goto :fail
call :find_android_jar
if errorlevel 1 goto :fail
call :find_d8
if errorlevel 1 goto :fail

if not exist "%~dp0..\assets" (
    echo [ERROR] Asset directory not found: "%~dp0..\assets"
    goto :fail
)

echo Java compiler: !JAVAC!
echo Android API:   !ANDROID_JAR!
echo D8:            !D8!
echo.
echo [1/5] Preparing isolated build directory...
if exist "!BUILD_DIR!" rmdir /s /q "!BUILD_DIR!"
mkdir "!CLASSES_DIR!" "!DEX_DIR!"
if errorlevel 1 goto :fail

echo [2/5] Compiling AdbAgent.java...
"!JAVAC!" --release 8 -encoding UTF-8 -cp "!ANDROID_JAR!" -d "!CLASSES_DIR!" AdbAgent.java
if errorlevel 1 goto :fail

echo [3/5] Converting classes to DEX...
call "!D8!" --min-api 21 --output "!DEX_DIR!" "!CLASSES_DIR!\com\adb\toolbox\AdbAgent.class" --lib "!ANDROID_JAR!"
if errorlevel 1 goto :fail
if not exist "!DEX_DIR!\classes.dex" (
    echo [ERROR] D8 did not produce classes.dex.
    goto :fail
)

echo [4/5] Packaging and validating server.jar...
"!JAR_TOOL!" cfM "!STAGED_JAR!" -C "!DEX_DIR!" classes.dex
if errorlevel 1 goto :fail
"!JAR_TOOL!" tf "!STAGED_JAR!" >nul
if errorlevel 1 goto :fail

rem Do not replace either published JAR until compilation, D8, and packaging pass.
if not exist "%~dp0build" mkdir "%~dp0build"
move /y "!STAGED_JAR!" "!OUTPUT_JAR!" >nul
if errorlevel 1 goto :fail

echo [5/5] Publishing verified JAR to Flutter assets...
copy /b /y "!OUTPUT_JAR!" "!ASSET_JAR!.new" >nul
if errorlevel 1 goto :fail
move /y "!ASSET_JAR!.new" "!ASSET_JAR!" >nul
if errorlevel 1 goto :fail

rmdir /s /q "!BUILD_DIR!"
echo.
echo BUILD SUCCESSFUL
echo Output: !OUTPUT_JAR!
echo Asset:  !ASSET_JAR!
popd
exit /b 0

:find_java
if defined JAVA_HOME if exist "%JAVA_HOME%\bin\javac.exe" if exist "%JAVA_HOME%\bin\jar.exe" (
    set "JAVAC=%JAVA_HOME%\bin\javac.exe"
    set "JAR_TOOL=%JAVA_HOME%\bin\jar.exe"
    exit /b 0
)
if defined JAVA_BIN if exist "%JAVA_BIN%\javac.exe" if exist "%JAVA_BIN%\jar.exe" (
    set "JAVAC=%JAVA_BIN%\javac.exe"
    set "JAR_TOOL=%JAVA_BIN%\jar.exe"
    exit /b 0
)
if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\javac.exe" if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\jar.exe" (
    set "JAVAC=%ProgramFiles%\Android\Android Studio\jbr\bin\javac.exe"
    set "JAR_TOOL=%ProgramFiles%\Android\Android Studio\jbr\bin\jar.exe"
    exit /b 0
)
where javac.exe >nul 2>nul
if not errorlevel 1 (
    where jar.exe >nul 2>nul
    if not errorlevel 1 (
        set "JAVAC=javac.exe"
        set "JAR_TOOL=jar.exe"
        exit /b 0
    )
)
echo [ERROR] JDK not found. Set JAVA_HOME to a JDK installation.
exit /b 1

:find_android_sdk
if defined ANDROID_SDK_ROOT if exist "%ANDROID_SDK_ROOT%" set "SDK_ROOT=%ANDROID_SDK_ROOT%"
if not defined SDK_ROOT if defined ANDROID_HOME if exist "%ANDROID_HOME%" set "SDK_ROOT=%ANDROID_HOME%"
if not defined SDK_ROOT if defined LOCALAPPDATA if exist "%LOCALAPPDATA%\Android\Sdk" set "SDK_ROOT=%LOCALAPPDATA%\Android\Sdk"
if not defined SDK_ROOT (
    if defined ANDROID_JAR if exist "%ANDROID_JAR%" exit /b 0
    echo [ERROR] Android SDK not found. Set ANDROID_SDK_ROOT.
    exit /b 1
)
exit /b 0

:find_android_jar
if defined ANDROID_JAR if exist "%ANDROID_JAR%" exit /b 0
set "ANDROID_JAR="
for /f "delims=" %%D in ('dir /b /ad /o-n "!SDK_ROOT!\platforms\android-*" 2^>nul') do (
    if not defined ANDROID_JAR if exist "!SDK_ROOT!\platforms\%%D\android.jar" set "ANDROID_JAR=!SDK_ROOT!\platforms\%%D\android.jar"
)
if not defined ANDROID_JAR (
    echo [ERROR] android.jar not found below "!SDK_ROOT!\platforms".
    exit /b 1
)
exit /b 0

:find_d8
if defined BUILD_TOOLS if exist "%BUILD_TOOLS%\d8.bat" set "D8=%BUILD_TOOLS%\d8.bat"
if not defined D8 if defined SDK_ROOT (
    for /f "delims=" %%D in ('dir /b /ad /o-n "!SDK_ROOT!\build-tools" 2^>nul') do (
        if not defined D8 if exist "!SDK_ROOT!\build-tools\%%D\d8.bat" set "D8=!SDK_ROOT!\build-tools\%%D\d8.bat"
    )
)
if not defined D8 (
    echo [ERROR] d8.bat not found. Set BUILD_TOOLS to an Android build-tools directory.
    exit /b 1
)
exit /b 0

:fail
set "BUILD_EXIT=%ERRORLEVEL%"
if "!BUILD_EXIT!"=="0" set "BUILD_EXIT=1"
if exist "!ASSET_JAR!.new" del /q "!ASSET_JAR!.new"
if exist "!BUILD_DIR!" rmdir /s /q "!BUILD_DIR!"
echo.
echo BUILD FAILED
popd
exit /b !BUILD_EXIT!
