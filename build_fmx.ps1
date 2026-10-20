$ErrorActionPreference = 'Continue'
$root   = 'D:\AI\Koda Projects\eurotorg-delphi'
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$env:PATH = $studio + '\bin64;' + $env:PATH
$dcc = $studio + '\bin64\dcc64.exe'
$lib = $studio + '\lib\Win64\release'
Write-Host '=== СБОРКА Warehouse.exe ==='
& $dcc -B -Q ("-E" + $root + '\bin') ("-N0" + $root + '\bin\dcu') ("-U" + $root + '\Source\Data;' + $root + '\Source\Forms') ("-U" + $lib) ($root + '\Warehouse.dpr')
Write-Host ('dcc exit: ' + $LASTEXITCODE)
