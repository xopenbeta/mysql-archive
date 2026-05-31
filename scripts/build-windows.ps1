#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$Arch,
    [Parameter(Mandatory)][string]$MysqlVersion
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    git clone https://github.com/microsoft/vcpkg.git $VcpkgRoot
    & "$VcpkgRoot\bootstrap-vcpkg.bat"
}

& "$VcpkgRoot\vcpkg.exe" install "openssl:$VcpkgTriplet" --no-print-usage

$OpenSSLRoot = "$VcpkgRoot\installed\$VcpkgTriplet"
Write-Host "OpenSSL root: $OpenSSLRoot"
$OpenSSLExe = "$OpenSSLRoot\tools\openssl\openssl.exe"
if (-not (Test-Path $OpenSSLExe)) {
    throw "OpenSSL executable not found at $OpenSSLExe. Ensure the vcpkg OpenSSL package installed correctly."
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
choco install ninja --no-progress -y | Out-Null
choco install winflexbison3 --no-progress -y | Out-Null

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

$OpenSSLExe = "$OpenSSLRoot\tools\openssl\openssl.exe"

$CmakeArgs = @(
    "-B", $BuildDir,
    "-S", $SrcDir,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_PREFIX=$InstallDir",
    "-DCMAKE_TOOLCHAIN_FILE=$VcpkgRoot\scripts\buildsystems\vcpkg.cmake",
    "-DWITH_SSL=system",
    "-DOPENSSL_ROOT_DIR=$OpenSSLRoot",
    "-DOPENSSL_INCLUDE_DIR=$OpenSSLRoot\include",
    "-DOPENSSL_LIBRARIES=$OpenSSLRoot\lib\libssl.lib;$OpenSSLRoot\lib\libcrypto.lib",
    "-DOPENSSL_EXECUTABLE=$OpenSSLExe",
    "-DWITH_UNIT_TESTS=OFF",
    "-DENABLED_LOCAL_INFILE=1",
    "-DDEFAULT_CHARSET=utf8mb4",
    "-DDEFAULT_COLLATION=utf8mb4_0900_ai_ci",
    "-DWITH_JEMALLOC=OFF"
)

if ($Series -eq '8.0') {
    $BoostDir = Join-Path $Workdir 'boost'
    New-Item -ItemType Directory -Force -Path $BoostDir | Out-Null
    $CmakeArgs += @("-DDOWNLOAD_BOOST=1", "-DWITH_BOOST=$BoostDir")
}

Write-Host "Running cmake configure..."
cmake @CmakeArgs

# ── 编译并安装 ──────────────────────────────────────────────────────
$Jobs = [System.Environment]::ProcessorCount
Write-Host "Building with $Jobs parallel jobs..."
cmake --build $BuildDir --config Release --parallel $Jobs

Write-Host "Installing..."
$installAttempts = 0
do {
    $installAttempts++
    cmake --install $BuildDir --config Release
    if ($LASTEXITCODE -ne 0) {
        if ($installAttempts -lt 3) {
            Write-Host "cmake --install failed (attempt $installAttempts/3, exit code $LASTEXITCODE), retrying in 10s..."
            Start-Sleep -Seconds 10
        } else {
            Write-Warning "cmake --install failed after 3 attempts (exit code $LASTEXITCODE). Continuing with packaging..."
        }
    }
} while ($LASTEXITCODE -ne 0 -and $installAttempts -lt 3)

# ── 打包 ────────────────────────────────────────────────────────────
Write-Host "Creating zip archive..."
Compress-Archive -Path $InstallDir -DestinationPath $ZipPath -Force

# ── 生成 SHA256 ──────────────────────────────────────────────────────
$Hash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
"$Hash  $ZipName" | Set-Content $ShaPath

Write-Host "Created artifact: $ZipPath"
Write-Host "Created checksum: $ShaPath"
Write-Host "Done"
