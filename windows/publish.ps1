# 배포용 빌드: 설치 없이 실행되는 단일 exe(64비트, .NET 포함)를 만들고 zip으로 묶는다.
#   powershell -File publish.ps1 -Version 0.1.0
# 결과: artifacts\MogoPrint-windows-x64.zip (MogoPrint.exe), artifacts\mogo-cli-windows-x64.zip (mogo-cli.exe)
param([string]$Version = "0.1.0")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $root "artifacts"
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue

$common = @(
    "-c", "Release", "-r", "win-x64", "--self-contained", "true",
    "-p:PublishSingleFile=true",
    "-p:IncludeNativeLibrariesForSelfExtract=true",  # pdfium.dll도 exe 안에 넣는다
    "-p:EnableCompressionInSingleFile=true",
    "-p:DebugType=none",
    "-p:Version=$Version"
)
dotnet publish (Join-Path $root "MogoPrint\MogoPrint.csproj") @common -o (Join-Path $out "app")
if ($LASTEXITCODE -ne 0) { throw "MogoPrint publish 실패" }
dotnet publish (Join-Path $root "Mogo.Cli\Mogo.Cli.csproj") @common -o (Join-Path $out "cli")
if ($LASTEXITCODE -ne 0) { throw "mogo-cli publish 실패" }

Compress-Archive -Path (Join-Path $out "app\MogoPrint.exe") -DestinationPath (Join-Path $out "MogoPrint-windows-x64.zip")
Compress-Archive -Path (Join-Path $out "cli\mogo-cli.exe") -DestinationPath (Join-Path $out "mogo-cli-windows-x64.zip")

Get-ChildItem $out -File | ForEach-Object {
    "{0}  {1:N1} MB  sha256 {2}" -f $_.Name, ($_.Length / 1MB), (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
}
