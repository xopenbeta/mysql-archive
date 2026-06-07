#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$Arch,
    [Parameter(Mandatory)][string]$MysqlVersion
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter()][string[]]$Arguments = @()
    )
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $Command $($Arguments -join ' ')"
    }
}

# 从版本号自动推导系列号，例如 8.0.41 → 8.0，8.4.4 → 8.4
$parts  = $MysqlVersion.Split('.')
$Series = "$($parts[0]).$($parts[1])"

$Workdir    = (Get-Location).Path
$Outdir     = Join-Path $Workdir 'dist-artifacts'
New-Item -ItemType Directory -Force -Path $Outdir | Out-Null

$ZipName    = "mysql-${MysqlVersion}-windows-${Arch}.zip"
$ZipPath    = Join-Path $Outdir $ZipName
$ShaPath    = "$ZipPath.sha256"
$InstallDir = Join-Path $Workdir "mysql-${MysqlVersion}"
$BuildDir   = Join-Path $Workdir 'mysql-build'
$SrcDir     = Join-Path $Workdir 'mysql-src'

Write-Host "=== Building MySQL ${MysqlVersion} for Windows/${Arch} ==="

# ── 安装 OpenSSL（使用 vcpkg，支持正确目标架构）────────────────────
# Chocolatey 的 openssl 包仅提供 x64 二进制，ARM64 构建必须用 vcpkg
Write-Host "Installing OpenSSL via vcpkg for $Arch..."
$VcpkgRoot    = 'C:\vcpkg'
$VcpkgTriplet = if ($Arch -eq 'arm64') { 'arm64-windows' } else { 'x64-windows' }

if (-not (Test-Path "$VcpkgRoot\vcpkg.exe")) {
    Write-Host "vcpkg not found at $VcpkgRoot. Cloning and bootstrapping vcpkg..."
    Invoke-Native -Command "git" -Arguments @("clone", "https://github.com/microsoft/vcpkg.git", $VcpkgRoot)
    Invoke-Native -Command "$VcpkgRoot\bootstrap-vcpkg.bat"
}

Invoke-Native -Command "$VcpkgRoot\vcpkg.exe" -Arguments @("install", "openssl:$VcpkgTriplet", "--no-print-usage")

$OpenSSLRoot = "$VcpkgRoot\installed\$VcpkgTriplet"
Write-Host "OpenSSL root: $OpenSSLRoot"
$OpenSSLExe = "$OpenSSLRoot\tools\openssl\openssl.exe"
if (-not (Test-Path $OpenSSLExe)) {
    $CmdOpenSSL = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($CmdOpenSSL -and (Test-Path $CmdOpenSSL.Source)) {
        $OpenSSLExe = $CmdOpenSSL.Source
        Write-Host "Using OpenSSL executable from PATH: $OpenSSLExe"
    } elseif (Test-Path "C:\Program Files\Git\usr\bin\openssl.exe") {
        $OpenSSLExe = "C:\Program Files\Git\usr\bin\openssl.exe"
        Write-Host "Using OpenSSL executable from Git: $OpenSSLExe"
    } else {
        Write-Warning "OpenSSL executable not found. CMake may set OPENSSL_EXECUTABLE-NOTFOUND."
        $OpenSSLExe = $null
    }
}

# MySQL 8.x 的 cmake/ssl.cmake (MYSQL_CHECK_SSL_DLLS) 硬编码搜索 *-x64.dll
# vcpkg 为 arm64 生成的是 *-arm64.dll，需要复制一份为 x64 命名才能被找到
if ($Arch -eq 'arm64') {
    Write-Host "Fixing OpenSSL DLL names for arm64 (MySQL ssl.cmake expects *-x64.dll)..."
    $BinDir = "$OpenSSLRoot\bin"
    @('libssl-3-arm64.dll:libssl-3-x64.dll', 'libcrypto-3-arm64.dll:libcrypto-3-x64.dll') | ForEach-Object {
        $src, $dst = $_ -split ':'
        $srcPath = Join-Path $BinDir $src
        $dstPath = Join-Path $BinDir $dst
        if ((Test-Path $srcPath) -and -not (Test-Path $dstPath)) {
            Copy-Item $srcPath $dstPath
            Write-Host "  Copied $src -> $dst"
        }
    }
}

# ── 安装 Ninja（cmake --build 使用） ────────────────────────────────
Invoke-Native -Command "choco" -Arguments @("install", "ninja", "--no-progress", "-y")
Invoke-Native -Command "choco" -Arguments @("install", "winflexbison3", "--no-progress", "-y")

# ── 下载 MySQL 源码 ─────────────────────────────────────────────────
$SrcUrl     = "https://cdn.mysql.com/Downloads/MySQL-${Series}/mysql-${MysqlVersion}.zip"
$SrcArchive = Join-Path $Workdir "mysql-${MysqlVersion}-src.zip"
Write-Host "Downloading source from $SrcUrl"
Invoke-WebRequest -Uri $SrcUrl -OutFile $SrcArchive -UseBasicParsing

Write-Host "Extracting source..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($SrcArchive, $Workdir)
# MySQL zip 内层目录名为 mysql-<version>，移至 SrcDir
$ExtractedDir = Get-ChildItem $Workdir -Directory -Filter "mysql-${MysqlVersion}" |
                Select-Object -First 1
if (-not $ExtractedDir) {
    throw "Could not find extracted MySQL source directory under $Workdir"
}
# 若目标目录已存在则先删除，避免 Rename-Item 报错
if (Test-Path $SrcDir) { Remove-Item -Recurse -Force $SrcDir }
Rename-Item -Path $ExtractedDir.FullName -NewName (Split-Path $SrcDir -Leaf)

# ── Patch MySQL install macros to tolerate missing PDB in Release builds ──
# Some MySQL releases install PDBs unconditionally on Windows. With Ninja+
# Release this can miss libmysql.pdb and fail cmake --install.
$InstallMacros = Join-Path $SrcDir 'cmake\install_macros.cmake'
if (Test-Path $InstallMacros) {
    $installMacrosText = [System.IO.File]::ReadAllText($InstallMacros)
    if ($installMacrosText -notmatch 'INSTALL\(FILES\s+\$\{debug_pdb_target_location\}[\s\S]*?OPTIONAL') {
        $installMacrosRegex = [System.Text.RegularExpressions.Regex]::new(
            'INSTALL\(FILES\s+\$\{debug_pdb_target_location\}([\s\S]*?CONFIGURATIONS\s+Release\s+RelWithDebInfo\s*)\)'
        )
        $patchedInstallMacros = $installMacrosRegex.Replace(
            $installMacrosText,
            'INSTALL(FILES ${debug_pdb_target_location}$1OPTIONAL)',
            1
        )

        if ($patchedInstallMacros -eq $installMacrosText) {
            Write-Warning "Could not patch install_macros.cmake for optional PDB install; build may fail if PDB is missing"
        } else {
            [System.IO.File]::WriteAllText($InstallMacros, $patchedInstallMacros)
            Write-Host "Patched install_macros.cmake to make PDB install optional"
        }
    }
} else {
    Write-Warning "install_macros.cmake not found at $InstallMacros; skipping optional PDB patch"
}

function Set-OptionalPdbInstall {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $content = [System.IO.File]::ReadAllText($Path)
    $updated = [System.Text.RegularExpressions.Regex]::Replace(
        $content,
        'file\(INSTALL(\s+DESTINATION\s+"[^"]+"\s+TYPE\s+FILE)\s+FILES\s+((?:"[^"]+\.pdb"\s*)+)\)',
        'file(INSTALL$1 OPTIONAL FILES $2)'
    )

    if ($updated -eq $content) {
        return $false
    }

    [System.IO.File]::WriteAllText($Path, $updated)
    return $true
}

# ── Patch MySQL 5.7 for modern MSVC STL compatibility ─────────────
# VS2022 + recent STL removes std::binary_function; 5.7 myisam sort.cc still inherits it.
if ($Series -eq '5.7') {
    $MyisamSortCc = Join-Path $SrcDir 'storage\myisam\sort.cc'
    if (-not (Test-Path $MyisamSortCc)) {
        throw "MySQL 5.7 compatibility patch target not found: $MyisamSortCc"
    }

    $sortCc = [System.IO.File]::ReadAllText($MyisamSortCc)
    $binaryFunctionPattern = ':\s*(?:public\s+)?std::binary_function\s*<[^>]+>'
    $matchCount = [System.Text.RegularExpressions.Regex]::Matches($sortCc, $binaryFunctionPattern).Count
    if ($matchCount -lt 1) {
        throw "MySQL 5.7 compatibility patch did not match std::binary_function inheritance in $MyisamSortCc"
    }

    $patchedSortCc = [System.Text.RegularExpressions.Regex]::Replace($sortCc, $binaryFunctionPattern, '', 1)
    if ($patchedSortCc -eq $sortCc) {
        throw "MySQL 5.7 compatibility patch made no changes in $MyisamSortCc"
    }

    [System.IO.File]::WriteAllText($MyisamSortCc, $patchedSortCc)
    Write-Host "Patched myisam sort.cc for VS2022 STL compatibility"

    $JsonDomH = Join-Path $SrcDir 'sql\json_dom.h'
    if (-not (Test-Path $JsonDomH)) {
        throw "MySQL 5.7 compatibility patch target not found: $JsonDomH"
    }

    $jsonDom = [System.IO.File]::ReadAllText($JsonDomH)
    $jsonMatchCount = [System.Text.RegularExpressions.Regex]::Matches($jsonDom, $binaryFunctionPattern).Count
    if ($jsonMatchCount -lt 1) {
        Write-Warning "MySQL 5.7 compatibility patch did not match std::binary_function inheritance in $JsonDomH; continuing"
    } else {
        $patchedJsonDom = [System.Text.RegularExpressions.Regex]::Replace($jsonDom, $binaryFunctionPattern, '', 1)
        if ($patchedJsonDom -eq $jsonDom) {
            throw "MySQL 5.7 compatibility patch made no changes in $JsonDomH"
        }

        [System.IO.File]::WriteAllText($JsonDomH, $patchedJsonDom)
        Write-Host "Patched sql/json_dom.h for VS2022 STL compatibility"
    }
}

# ── CMake 平台参数 ───────────────────────────────────────────────────
# x86_64 → x64，arm64 → ARM64
$CmakePlatform = if ($Arch -eq 'x86_64') { 'x64' } else { 'ARM64' }

# 找 Visual Studio
$VsWhere = "${Env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VsPath  = & $VsWhere -latest -property installationPath 2>$null
if (-not $VsPath) { $VsPath = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise' }

# 初始化 MSVC 环境（让 cl.exe / link.exe 在 PATH 中）
$VcVarsAll = Join-Path $VsPath 'VC\Auxiliary\Build\vcvarsall.bat'
if (Test-Path $VcVarsAll) {
    # 在当前进程中激活对应架构的工具链
    $EnvBatch = if ($Arch -eq 'arm64') { "arm64" } else { "x64" }
    $TmpFile  = [System.IO.Path]::GetTempFileName() + ".ps1"
    cmd /c "`"$VcVarsAll`" $EnvBatch && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

# ── CMake 配置 ──────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$CmakeArgs = @(
    "-B", $BuildDir,
    "-S", $SrcDir,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_PREFIX=$InstallDir",
    "-DCMAKE_TOOLCHAIN_FILE=$VcpkgRoot\scripts\buildsystems\vcpkg.cmake",
    "-DENABLE_DTRACE=OFF",
    "-DWITH_SSL=system",
    "-DOPENSSL_ROOT_DIR=$OpenSSLRoot",
    "-DOPENSSL_INCLUDE_DIR=$OpenSSLRoot\include",
    "-DOPENSSL_LIBRARIES=$OpenSSLRoot\lib\libssl.lib;$OpenSSLRoot\lib\libcrypto.lib",
    "-DWITH_UNIT_TESTS=OFF",
    "-DENABLED_LOCAL_INFILE=1",
    "-DDEFAULT_CHARSET=utf8mb4",
    "-DWITH_JEMALLOC=OFF"
)

if ($Series -eq '5.7') {
    $CmakeArgs += "-DDEFAULT_COLLATION=utf8mb4_general_ci"
} else {
    $CmakeArgs += "-DDEFAULT_COLLATION=utf8mb4_0900_ai_ci"
}

if ($Series -eq '8.0' -or $Series -eq '5.7') {
    $BoostDir = Join-Path $Workdir 'boost'
    New-Item -ItemType Directory -Force -Path $BoostDir | Out-Null
    $CmakeArgs += @("-DDOWNLOAD_BOOST=1", "-DWITH_BOOST=$BoostDir")
}

if ($Series -eq '5.7') {
    $CmakeArgs += "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    $CmakeArgs += "-DCMAKE_CXX_STANDARD=14"
}

if ($Arch -eq 'arm64') {
    # On some arm64 Windows runners, InnoDB picks a Windows MM fence path that
    # pulls x86-style intrinsics and fails in mmintrin.h (C1189).
    $CmakeArgs += "-DHAVE_WINDOWS_MM_FENCE=0"
}

if ($OpenSSLExe) {
    $CmakeArgs += "-DOPENSSL_EXECUTABLE=$OpenSSLExe"
}

Write-Host "Running cmake configure..."
cmake @CmakeArgs
if ($LASTEXITCODE -ne 0) {
    throw "cmake configure failed (exit code $LASTEXITCODE)"
}

# Some releases still generate cmake_install.cmake entries that install PDBs
# unconditionally even after source macro patching. Make generated install rules
# tolerate missing Release PDBs before running the install step.
$optionalPdbPatchCount = 0
Get-ChildItem -Path $BuildDir -Recurse -File -Filter "cmake_install.cmake" | ForEach-Object {
    if (Set-OptionalPdbInstall -Path $_.FullName) {
        $optionalPdbPatchCount++
    }
}
Write-Host "Patched $optionalPdbPatchCount generated cmake_install.cmake file(s) for optional PDB installs"

# ── Patch Boost 1.77.0 for ARM64 MSVC (intel_intrinsics.hpp bug) ───
# Boost 1.77 guards with !defined(__arm__) but omits !defined(__aarch64__)
# and !defined(_M_ARM64). On ARM64 Windows MSVC _M_X64 may be set,
# causing the x86-only _addcarry_u32/_subborrow_u32 to be compiled.
# Fixed upstream in Boost 1.78.0; patch here since MySQL 8.0 requires 1.77.
if ($Arch -eq 'arm64' -and $Series -eq '8.0') {
    $BoostIntelHpp = Join-Path $BoostDir "boost_1_77_0\boost\multiprecision\cpp_int\intel_intrinsics.hpp"
    if (Test-Path $BoostIntelHpp) {
        $hpp = [System.IO.File]::ReadAllText($BoostIntelHpp)
        if ($hpp -notmatch '_M_ARM64.*ARM64 guard') {
            $guard  = "// ARM64 guard (patched for Boost 1.77 / MySQL 8.0 ARM64 MSVC build)`r`n"
            $guard += "#if !defined(_M_ARM64) && !defined(__aarch64__)`r`n"
            $footer = "`r`n#endif // !defined(_M_ARM64) && !defined(__aarch64__)`r`n"
            [System.IO.File]::WriteAllText($BoostIntelHpp, $guard + $hpp + $footer)
            Write-Host "Patched Boost 1.77 intel_intrinsics.hpp for ARM64 MSVC compatibility"
        }
    } else {
        Write-Warning "Boost intel_intrinsics.hpp not found at $BoostIntelHpp; skipping patch"
    }
}

if ($Arch -eq 'arm64') {
    # Some arm64 runners still emit -DHAVE_WINDOWS_MM_FENCE in generated rules,
    # which triggers mmintrin.h C1189 in InnoDB. Strip it from ninja rules.
    Write-Host "Removing HAVE_WINDOWS_MM_FENCE from generated ninja rules for arm64..."
    $patchedFiles = 0
    Get-ChildItem -Path $BuildDir -Recurse -File -Filter "*.ninja" | ForEach-Object {
        $content = [System.IO.File]::ReadAllText($_.FullName)
        $updated = $content -replace '(?<=\s)-DHAVE_WINDOWS_MM_FENCE(?=\s|$)', ''
        if ($updated -ne $content) {
            [System.IO.File]::WriteAllText($_.FullName, $updated)
            $patchedFiles++
        }
    }
    Write-Host "Patched $patchedFiles ninja file(s)"
}

# ── 编译并安装 ──────────────────────────────────────────────────────
$Jobs = [System.Environment]::ProcessorCount
Write-Host "Building with $Jobs parallel jobs..."
cmake --build $BuildDir --config Release --parallel $Jobs
if ($LASTEXITCODE -ne 0) {
    throw "cmake --build failed (exit code $LASTEXITCODE)"
}

Write-Host "Installing..."
$installAttempts = 0
$installSucceeded = $false
do {
    $installAttempts++
    cmake --install $BuildDir --config Release
    if ($LASTEXITCODE -ne 0) {
        if ($installAttempts -lt 3) {
            Write-Host "cmake --install failed (attempt $installAttempts/3, exit code $LASTEXITCODE), retrying in 10s..."
            Start-Sleep -Seconds 10
        } else {
            throw "cmake --install failed after 3 attempts (exit code $LASTEXITCODE)"
        }
    } else {
        $installSucceeded = $true
    }
} while (-not $installSucceeded -and $installAttempts -lt 3)

$ExpectedBinaries = @(
    (Join-Path $InstallDir 'bin\mysqld.exe'),
    (Join-Path $InstallDir 'bin\mysql.exe')
)

$MissingBinaries = $ExpectedBinaries | Where-Object { -not (Test-Path $_) }
if ($MissingBinaries.Count -gt 0) {
    throw "Install output is incomplete. Missing expected binaries: $($MissingBinaries -join ', ')"
}

# ── 打包 ────────────────────────────────────────────────────────────
Write-Host "Creating zip archive..."
Compress-Archive -Path $InstallDir -DestinationPath $ZipPath -Force

# ── 生成 SHA256 ──────────────────────────────────────────────────────
$Hash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
"$Hash  $ZipName" | Set-Content $ShaPath

Write-Host "Created artifact: $ZipPath"
Write-Host "Created checksum: $ShaPath"
Write-Host "Done"
