param([string]$CachePath = $env:NELISP_CALC_RATES)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (!$CachePath) { $CachePath = Join-Path $project 'target/currency-rates.tsv' }
$CachePath = [IO.Path]::GetFullPath($CachePath)
New-Item -ItemType Directory -Force (Split-Path $CachePath -Parent) | Out-Null
$source = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml'
$response = Invoke-WebRequest -Uri $source -TimeoutSec 20 -MaximumRedirection 3
$settings = [Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$reader = [Xml.XmlReader]::Create([IO.StringReader]::new($response.Content), $settings)
try { $document = [Xml.XmlDocument]::new(); $document.XmlResolver = $null; $document.Load($reader) } finally { $reader.Dispose() }
$day = $document.SelectSingleNode('//*[local-name()="Cube" and @time]')
if (!$day -or $day.time -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'ECB date missing' }
$null = [DateTime]::ParseExact($day.time, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('date=' + $day.time)
$lines.Add("EUR`t1")
$seen = @{EUR = $true}
foreach ($rate in $day.SelectNodes('*[local-name()="Cube"]')) {
    $code = [string]$rate.currency; $value = [string]$rate.rate
    if ($code -notmatch '^[A-Z]{3}$' -or $value -notmatch '^\d+(\.\d+)?$' -or $seen.ContainsKey($code)) { throw 'Invalid ECB rate row' }
    if ([decimal]::Parse($value, [Globalization.CultureInfo]::InvariantCulture) -le 0) { throw 'Nonpositive ECB rate' }
    $seen[$code] = $true
    $lines.Add($code + "`t" + $value)
}
if ($lines.Count -lt 3) { throw 'ECB response contains no foreign rates' }
$temporary = $CachePath + '.tmp'
[IO.File]::WriteAllText($temporary, ($lines -join "`n") + "`n", [Text.Encoding]::ASCII)
Move-Item -LiteralPath $temporary -Destination $CachePath -Force
@{ source = $source; fetchedUtc = [DateTime]::UtcNow.ToString('o'); rateDate = [string]$day.time } | ConvertTo-Json | Set-Content -LiteralPath ($CachePath + '.metadata.json') -Encoding utf8
Write-Output ('ECB cache updated: ' + $day.time + ' (' + ($lines.Count - 1) + ' currencies)')
