[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [Alias("i")]
  [string]$InputFile = "resume-zh_CN.tex",

  [Parameter(Position = 1)]
  [Alias("o")]
  [string]$OutputFile,

  [string]$XeLaTeX,

  [ValidateRange(1, 5)]
  [int]$Runs = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = Split-Path -Parent $PSCommandPath

if ([string]::IsNullOrWhiteSpace($InputFile)) {
  $InputFile = "resume-zh_CN.tex"
}

$InputPath = if ([IO.Path]::IsPathRooted($InputFile)) {
  $InputFile
} else {
  Join-Path $ProjectDir $InputFile
}

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
  throw "Input TeX file not found: $InputPath"
}

$InputItem = Get-Item -LiteralPath $InputPath
if ($InputItem.Extension -ne ".tex") {
  throw "Input file must be a .tex file: $($InputItem.FullName)"
}

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
  $OutputFile = [IO.Path]::ChangeExtension($InputItem.Name, ".pdf")
} elseif ([IO.Path]::GetExtension($OutputFile) -eq "") {
  $OutputFile = "$OutputFile.pdf"
} elseif ([IO.Path]::GetExtension($OutputFile) -ne ".pdf") {
  throw "Output file must be a .pdf file: $OutputFile"
}

$OutputPath = if ([IO.Path]::IsPathRooted($OutputFile)) {
  $OutputFile
} else {
  Join-Path $ProjectDir $OutputFile
}

$OutputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($OutputDir) -and -not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

if ([string]::IsNullOrWhiteSpace($XeLaTeX)) {
  $Command = Get-Command xelatex -ErrorAction SilentlyContinue
  if ($Command) {
    $XeLaTeX = $Command.Source
  } elseif (Test-Path -LiteralPath "E:\MiKTeX\miktex\bin\x64\xelatex.exe" -PathType Leaf) {
    $XeLaTeX = "E:\MiKTeX\miktex\bin\x64\xelatex.exe"
  } else {
    throw "Cannot find xelatex. Add MiKTeX to PATH or pass -XeLaTeX <path-to-xelatex.exe>."
  }
}

$JobName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
$GeneratedPdf = Join-Path $ProjectDir "$JobName.pdf"
$Arguments = @(
  "-interaction=nonstopmode",
  "-halt-on-error",
  "-jobname=$JobName",
  $InputItem.FullName
)

Push-Location $ProjectDir
try {
  for ($Run = 1; $Run -le $Runs; $Run++) {
    & $XeLaTeX @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "XeLaTeX failed on run $Run with exit code $LASTEXITCODE."
    }
  }
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath $GeneratedPdf -PathType Leaf)) {
  throw "XeLaTeX finished but did not create expected PDF: $GeneratedPdf"
}

if ($GeneratedPdf -ne $OutputPath) {
  Move-Item -LiteralPath $GeneratedPdf -Destination $OutputPath -Force
}

Write-Host "Compiled $($InputItem.Name) -> $OutputPath"
