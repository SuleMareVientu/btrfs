@echo off
setlocal enabledelayedexpansion

echo ===================================================
echo  WinBtrfs MSVC AMD64 Release Build and Test-Signing Script
echo ===================================================

:: 1. Detect the latest installed Windows SDK / WDK version
set "LATEST_SDK="
if exist "%ProgramFiles(x86)%\Windows Kits\10\Include\" (
    for /f "tokens=*" %%v in ('dir /b /o-n "%ProgramFiles(x86)%\Windows Kits\10\Include\10.*" 2^>nul') do (
        if not defined LATEST_SDK set "LATEST_SDK=%%v"
    )
)

if defined LATEST_SDK (
    echo [1/7] Detected Latest Windows SDK / WDK Version: !LATEST_SDK!
) else (
    echo [1/7] [WARNING] Could not locate Windows Kits directory.
)

:: 2. Auto-detect and initialize the LATEST Visual Studio Environment
if "%VSCMD_ARG_TGT_ARCH%"=="" (
    echo [2/7] Locating LATEST Visual Studio installation...
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    set "VCVARS="

    if exist "!VSWHERE!" (
        for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
            if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" (
                set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
            )
        )
    )

    :: Fallback checks if vswhere is not found
    if not defined VCVARS (
        if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
            set "VCVARS=%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
        ) else if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat" (
            set "VCVARS=%ProgramFiles%\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
        ) else if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" (
            set "VCVARS=%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
        )
    )

    if defined VCVARS (
        echo Found Latest VS: "!VCVARS!"
        if defined LATEST_SDK (
            call "!VCVARS!" !LATEST_SDK!
        ) else (
            call "!VCVARS!"
        )
    ) else (
        echo [WARNING] Could not find vcvars64.bat automatically. Assuming active environment...
    )
) else (
    echo [2/7] Using active Visual Studio environment ^(%VSCMD_ARG_TGT_ARCH%^).
)

:: Verify WDK headers availability
if defined WindowsSdkDir if defined WindowsSDKVersion (
    if exist "!WindowsSdkDir!Include\!WindowsSDKVersion!km\ntifs.h" (
        echo [INFO] WDK Kernel headers verified at: "!WindowsSdkDir!Include\!WindowsSDKVersion!km"
    ) else (
        echo [WARNING] WDK kernel headers ^(km\ntifs.h^) not found under !WindowsSdkDir!Include\!WindowsSDKVersion!. Make sure WDK is installed.
    )
)

:: 3. Configure & Build with CMake
set "BUILD_DIR=build\release\amd64"

echo.
echo [3/7] Configuring CMake for msvc-amd64 in Release mode...
cmake -B "%BUILD_DIR%" -G Ninja -DCMAKE_TOOLCHAIN_FILE=msvc-amd64.cmake -DCMAKE_BUILD_TYPE=Release
if %ERRORLEVEL% neq 0 (
    echo [ERROR] CMake configuration failed.
    exit /b %ERRORLEVEL%
)

echo.
echo [4/7] Building WinBtrfs binaries...
cmake --build "%BUILD_DIR%"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Build failed.
    exit /b %ERRORLEVEL%
)

:: 4. Package INF files & Generate Catalog (.cat) File
echo.
echo [5/7] Packaging INF files and generating Catalog (btrfs.cat)...
copy /y src\btrfs.inf "%BUILD_DIR%\" >nul
copy /y src\btrfs-vol.inf "%BUILD_DIR%\" >nul

(
    echo [CatalogHeader]
    echo Name=btrfs.cat
    echo PublicVersion=0x0000001
    echo EncodingType=0x00010001
    echo CATATTR1=0x10010001:OSAttr:2:10.0
    echo.
    echo [CatalogFiles]
    echo ^<hash^>btrfs.inf=btrfs.inf
    echo ^<hash^>btrfs-vol.inf=btrfs-vol.inf
    echo ^<hash^>btrfs.sys=btrfs.sys
    echo ^<hash^>mkbtrfs.exe=mkbtrfs.exe
    echo ^<hash^>shellbtrfs.dll=shellbtrfs.dll
    echo ^<hash^>ubtrfs.dll=ubtrfs.dll
) > "%BUILD_DIR%\btrfs.cdf"

if defined WindowsSdkVerBinPath (
    if exist "!WindowsSdkVerBinPath!x64\makecat.exe" (
        pushd "%BUILD_DIR%"
        "!WindowsSdkVerBinPath!x64\makecat.exe" -v btrfs.cdf
        popd
    ) else (
        echo [WARNING] makecat.exe not found at "!WindowsSdkVerBinPath!x64\makecat.exe". Catalog file skipped.
    )
) else (
    echo [WARNING] WindowsSdkVerBinPath not defined. Catalog file skipped.
)

:: 5. Create / Retrieve Universal Test Certificate & Test-Sign Binaries
echo.
echo [6/7] Resolving Universal Test Certificate and Test-Signing Binaries...

if not exist "btrfs_test.pfx" (
    echo Generating new universal test certificate ^(btrfs_test.pfx / btrfs_cert.cer^) in repository root...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Subject -match 'CN=Btrfs Driver Cert' } | Select-Object -First 1; if (-not $c) { $c = New-SelfSignedCertificate -Subject 'CN=Btrfs Driver Cert' -Type CodeSigningCert -CertStoreLocation 'Cert:\CurrentUser\My' }; $pwd = ConvertTo-SecureString 'btrfs' -AsPlainText -Force; Export-PfxCertificate -Cert $c -FilePath 'btrfs_test.pfx' -Password $pwd -Force | Out-Null; Export-Certificate -Cert $c -FilePath 'btrfs_cert.cer' -Force | Out-Null"
)

if exist "btrfs_cert.cer" (
    copy /y "btrfs_cert.cer" "%BUILD_DIR%\" >nul
)

if exist "btrfs_test.pfx" (
    if defined WindowsSdkVerBinPath (
        if exist "!WindowsSdkVerBinPath!x64\signtool.exe" (
            echo Signing binaries with btrfs_test.pfx...
            "!WindowsSdkVerBinPath!x64\signtool.exe" sign /fd sha256 /f btrfs_test.pfx /p btrfs /t http://timestamp.digicert.com "%BUILD_DIR%\btrfs.cat" "%BUILD_DIR%\btrfs.sys" "%BUILD_DIR%\shellbtrfs.dll" "%BUILD_DIR%\ubtrfs.dll" "%BUILD_DIR%\mkbtrfs.exe"
        ) else (
            echo [WARNING] signtool.exe not found at "!WindowsSdkVerBinPath!x64\signtool.exe". Signing skipped.
        )
    ) else (
        echo [WARNING] WindowsSdkVerBinPath not defined. Signing skipped.
    )
) else (
    echo [WARNING] btrfs_test.pfx not found. Test-signing skipped.
)

:: 6. Create Distribution ZIP Package
set "DIST_DIR=build\dist_staging"
set "ZIP_OUT=build\btrfs-release-amd64.zip"

echo.
echo [7/7] Creating Distribution ZIP package (%ZIP_OUT%)...

if exist "%DIST_DIR%" rmdir /s /q "%DIST_DIR%"
mkdir "%DIST_DIR%"
mkdir "%DIST_DIR%\amd64"

copy /y "%BUILD_DIR%\btrfs.inf" "%DIST_DIR%\" >nul
copy /y "%BUILD_DIR%\btrfs-vol.inf" "%DIST_DIR%\" >nul
if exist "%BUILD_DIR%\btrfs.cat" copy /y "%BUILD_DIR%\btrfs.cat" "%DIST_DIR%\" >nul
if exist "%BUILD_DIR%\btrfs_cert.cer" copy /y "%BUILD_DIR%\btrfs_cert.cer" "%DIST_DIR%\" >nul

echo =================================================== > "%DIST_DIR%\readme.txt"
echo  WinBtrfs Driver Installation Instructions >> "%DIST_DIR%\readme.txt"
echo =================================================== >> "%DIST_DIR%\readme.txt"
echo. >> "%DIST_DIR%\readme.txt"
echo 1^) Install the Certificate: >> "%DIST_DIR%\readme.txt"
echo    You must install btrfs_cert.cer into the "Trusted Root Certification Authorities" >> "%DIST_DIR%\readme.txt"
echo    store ^(and "Trusted Publishers"^) on that machine. >> "%DIST_DIR%\readme.txt"
echo. >> "%DIST_DIR%\readme.txt"
echo 2^) Enable Test Mode: >> "%DIST_DIR%\readme.txt"
echo    The target machine must also have Windows Test Mode enabled: >> "%DIST_DIR%\readme.txt"
echo    bcdedit /set testsigning on >> "%DIST_DIR%\readme.txt"
echo    ^(Reboot system after enabling Test Mode^). >> "%DIST_DIR%\readme.txt"
echo    Note: On systems with UEFI Secure Boot enabled, Secure Boot may need >> "%DIST_DIR%\readme.txt"
echo    to be disabled in BIOS/UEFI settings for Test Mode to take effect. >> "%DIST_DIR%\readme.txt"
echo. >> "%DIST_DIR%\readme.txt"
echo 3^) Install btrfs.inf: >> "%DIST_DIR%\readme.txt"
echo    Right-click btrfs.inf and select "Install". >> "%DIST_DIR%\readme.txt"

copy /y "%BUILD_DIR%\btrfs.sys" "%DIST_DIR%\amd64\" >nul
copy /y "%BUILD_DIR%\shellbtrfs.dll" "%DIST_DIR%\amd64\" >nul
copy /y "%BUILD_DIR%\ubtrfs.dll" "%DIST_DIR%\amd64\" >nul
copy /y "%BUILD_DIR%\mkbtrfs.exe" "%DIST_DIR%\amd64\" >nul

if exist "%ZIP_OUT%" del /f /q "%ZIP_OUT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path '%ZIP_OUT%') { Remove-Item -Path '%ZIP_OUT%' -Force -ErrorAction SilentlyContinue }; Compress-Archive -Path '%DIST_DIR%\*' -DestinationPath '%ZIP_OUT%' -Force"

echo.
echo ===================================================
echo  Build, Packaging, Test-Signing, and ZIP Archive Complete!
echo  Distribution ZIP Archive: %ZIP_OUT%
echo.
echo  ZIP Archive Contents:
echo  - btrfs.inf          (Driver INF - Root)
echo  - btrfs-vol.inf      (Volume INF - Root)
echo  - btrfs.cat          (Signed Catalog - Root)
echo  - btrfs_cert.cer     (Public Cert - Root)
echo  - readme.txt         (Installation Instructions - Root)
echo  - amd64\btrfs.sys    (Signed Driver Binary)
echo  - amd64\shellbtrfs.dll (Signed Shell Extension)
echo  - amd64\ubtrfs.dll   (Signed Support Library)
echo  - amd64\mkbtrfs.exe  (Signed Format Utility)
echo ===================================================
