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

$Workdir  = (Get-Location).Path
$Outdir   = Join-Path $Workdir 'dist-artifacts'
New-Item -ItemType Directory -Force -Path $Outdir | Out-Null

$ZipName  = "mysql-${MysqlVersion}-windows-${Arch}.zip"
$ZipPath  = Join-Path $Outdir $ZipName
$ShaPath  = "$ZipPath.sha256"

Write-Host "Building placeholder package for arch=$Arch mysql=$MysqlVersion series=$Series"

# Download source tarball (best-effort)
$SrcUrl     = "https://cdn.mysql.com/Downloads/MySQL-${Series}/mysql-${MysqlVersion}.zip"
$SrcArchive = Join-Path $Workdir "mysql-${MysqlVersion}-src.zip"
try {
    Write-Host "Attempting to download source from $SrcUrl"
    Invoke-WebRequest -Uri $SrcUrl -OutFile $SrcArchive -UseBasicParsing -TimeoutSec 60
} catch {
    Write-Host "Download failed or not present; continuing with placeholder"
    if (Test-Path $SrcArchive) { Remove-Item $SrcArchive }
}

# Create a minimal package layout
$BuildTmp  = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
$PkgDir    = Join-Path $BuildTmp "mysql-${MysqlVersion}"
$BinDir    = Join-Path $PkgDir 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

"Placeholder MySQL build for windows/$Arch $MysqlVersion" | Set-Content (Join-Path $PkgDir 'README.txt')

@"
@echo off
echo This is a placeholder mysqld binary for testing CI artifacts.
"@ | Set-Content (Join-Path $BinDir 'mysqld.bat')

# Pack the zip
Compress-Archive -Path (Join-Path $BuildTmp 'mysql-*') -DestinationPath $ZipPath -Force

# Generate SHA256
$Hash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
"$Hash  $ZipName" | Set-Content $ShaPath

Write-Host "Created artifact: $ZipPath"
Write-Host "Created checksum: $ShaPath"

# Clean up
Remove-Item -Recurse -Force $BuildTmp

Write-Host "Done"
