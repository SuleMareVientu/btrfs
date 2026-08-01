# Building, Catalog Packaging, and Test-Signing WinBtrfs

This guide details how to build WinBtrfs on Windows with Microsoft Visual Studio (MSVC) / CMake, generate driver catalogs, test-sign the binaries, and package the release into a distribution ZIP archive.

---

## 1. Automated Quick Start

An automated batch script [build_msvc_amd64.bat](build_msvc_amd64.bat) is included in the project root. It auto-detects your installed Visual Studio environment and latest Windows SDK/WDK, builds in Release mode, generates the `.cat` catalog file, creates a test certificate, test-signs the binaries, and outputs a distribution ZIP archive:

```cmd
build_msvc_amd64.bat
```

---

## 2. Source & WDK Header Compatibility Notes

When building against modern Windows SDK / WDK releases (e.g., Windows 10/11 SDK):

1. **WDK Path Detection (`CMakeLists.txt`)**:
   - CMake automatically resolves the Windows SDK/WDK path via `%WindowsSdkDir%` / `%WindowsSDKVersion%` (e.g. `%WindowsSdkDir%Include\%WindowsSDKVersion%km`).
2. **Target Version (`NTDDI_VERSION`)**:
   - Headers and driver definitions target modern Windows versions (`NTDDI_VERSION >= 0x0A000006` for Windows 10 RS5 / 1809+ structures).
3. **Struct Redefinition Guards**:
   - Structs such as `FILE_CASE_SENSITIVE_INFORMATION`, `FILE_DISPOSITION_INFORMATION_EX`, and `FILE_STAT_INFORMATION` are guarded with `#ifndef _MSC_VER` in [src/fileinfo.c](src/fileinfo.c) and [src/tests/test.h](src/tests/test.h) to use standard SDK definitions when compiled with MSVC.
4. **Native MSVC Toolchain Support**:
   - The toolchain file [msvc-amd64.cmake](msvc-amd64.cmake) automatically uses native MSVC compiler tools (`cl` / `rc`) when building natively on Windows.

---

## 3. Prerequisites

1. **Visual Studio 2022** (or later) with:
   - **Desktop development with C++** (MSVC compiler v143+, C++ tools)
   - **C++ CMake tools for Windows** (or standalone CMake 3.16+)
   - **Ninja build system**
2. **Windows SDK and WDK**:
   - Windows 10 or 11 SDK & WDK installed for `makecat.exe` and `signtool.exe` (accessible via `%WindowsSdkVerBinPath%x64\` or system `PATH`).

---

## 4. Manual Command-Line Build Instructions

### Step 1: Open Developer Environment
Launch **x64 Native Tools Command Prompt for VS 2022**, or initialize the environment in Command Prompt / PowerShell:

```cmd
"%VCINSTALLDIR%\Auxiliary\Build\vcvars64.bat"
```

### Step 2: Configure and Compile (AMD64 / x64)

```cmd
cmake -B build/release/amd64 -G Ninja -DCMAKE_TOOLCHAIN_FILE=msvc-amd64.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build/release/amd64
```

### Output Binaries
Compiled binaries are located in `build/release/amd64/`:
- `btrfs.sys` (Kernel filesystem driver)
- `shellbtrfs.dll` (Shell extension DLL)
- `ubtrfs.dll` (User-mode support DLL)
- `mkbtrfs.exe` (Format utility)
- `test.exe` (Test suite runner)

---

## 5. Catalog File (`.cat`) Generation via `makecat.exe`

> [!NOTE]
> **Why `makecat.exe` instead of `Inf2Cat.exe`?**  
> `Inf2Cat.exe` in recent WDK releases can fail with `0x8007000B` due to deprecated 32-bit dependencies. Using native 64-bit `makecat.exe` with a Catalog Definition File (`.cdf`) is the recommended modern workaround.

### Single-Folder `.cdf` Generation (Release Package)

1. Create a `btrfs.cdf` file in your release directory (or target folder containing the driver files):

```ini
[CatalogHeader]
Name=btrfs.cat
PublicVersion=0x0000001
EncodingType=0x00010001
CATATTR1=0x10010001:OSAttr:2:10.0

[CatalogFiles]
<hash>btrfs.inf=btrfs.inf
<hash>btrfs-vol.inf=btrfs-vol.inf
<hash>btrfs.sys=btrfs.sys
<hash>mkbtrfs.exe=mkbtrfs.exe
<hash>shellbtrfs.dll=shellbtrfs.dll
<hash>ubtrfs.dll=ubtrfs.dll
```

*(Alternatively, use the existing multi-arch template [src/btrfs.cdf](src/btrfs.cdf)).*

2. Run `makecat.exe` to construct `btrfs.cat`:

**In PowerShell:**
```powershell
& "$env:WindowsSdkVerBinPath\x64\makecat.exe" -v btrfs.cdf
```

**In Command Prompt:**
```cmd
"%WindowsSdkVerBinPath%x64\makecat.exe" -v btrfs.cdf
```

---

## 6. Universal Test Code-Signing Certificate

A universal repository test certificate (`btrfs_test.pfx`, password: `btrfs`) and matching public certificate (`btrfs_cert.cer`) are maintained in the root folder of the repository.

If `btrfs_test.pfx` is missing, [build_msvc_amd64.bat](build_msvc_amd64.bat) automatically generates it once via PowerShell:

```powershell
# Generate self-signed Code Signing certificate
$cert = New-SelfSignedCertificate -Subject "CN=Btrfs Driver Cert" -Type CodeSigningCert -CertStoreLocation "Cert:\CurrentUser\My"

# Export PFX (private/public pair) & CER (public key)
$pwd = ConvertTo-SecureString "btrfs" -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath "btrfs_test.pfx" -Password $pwd
Export-Certificate -Cert $cert -FilePath "btrfs_cert.cer"
```

---

## 7. Signing the Driver Binaries & Catalog

Sign the `.cat` catalog file, `.sys` kernel driver, `.dll` shell extensions, and `.exe` utilities using `signtool.exe` with `btrfs_test.pfx`:

**In Command Prompt:**
```cmd
"%WindowsSdkVerBinPath%x64\signtool.exe" sign /fd sha256 /f btrfs_test.pfx /p btrfs /t http://timestamp.digicert.com build\release\amd64\btrfs.cat build\release\amd64\btrfs.sys build\release\amd64\shellbtrfs.dll build\release\amd64\ubtrfs.dll build\release\amd64\mkbtrfs.exe
```

**In PowerShell:**
```powershell
& "$env:WindowsSdkVerBinPath\x64\signtool.exe" sign /fd sha256 /f btrfs_test.pfx /p btrfs /t http://timestamp.digicert.com build\release\amd64\btrfs.cat build\release\amd64\btrfs.sys build\release\amd64\shellbtrfs.dll build\release\amd64\ubtrfs.dll build\release\amd64\mkbtrfs.exe
```

---

## 8. Installing & Testing on a Target Machine

To test load the self-signed driver on Windows:

1. **Enable Test Mode (Administrator Command Prompt / PowerShell)**:
   ```cmd
   bcdedit /set testsigning on
   ```
   *Reboot your system after changing this setting.*

   > [!IMPORTANT]
   > On systems with **UEFI Secure Boot** enabled, Windows prevents Test Mode from loading self-signed drivers. You must disable Secure Boot in your system's BIOS/UEFI settings for Test Mode to take effect.

2. **Trust the Certificate**:
   - Double-click `btrfs_cert.cer`.
   - Select **Install Certificate...** -> **Local Machine**.
   - Place the certificate in **Trusted Root Certification Authorities** (and **Trusted Publishers**).

3. **Install Driver**:
   - Unpack `btrfs-release-amd64.zip`.
   - Right-click `btrfs.inf` and choose **Install**.

---

## 9. Distribution Archive (.zip)

Running `build_msvc_amd64.bat` automatically packages a distribution-ready archive at `build\btrfs-release-amd64.zip` with the following structure:

```text
btrfs-release-amd64.zip
├── btrfs.inf          (Driver INF - Root)
├── btrfs-vol.inf      (Volume INF - Root)
├── btrfs.cat          (Signed Catalog file - Root)
├── btrfs_cert.cer     (Public test-signing certificate - Root)
├── readme.txt         (Installation instructions - Root)
└── amd64\
    ├── btrfs.sys      (Signed kernel driver)
    ├── shellbtrfs.dll (Signed shell extension)
    ├── ubtrfs.dll     (Signed support library)
    └── mkbtrfs.exe    (Signed formatting tool)
```
