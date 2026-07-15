[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$CsvPath = @(),

    [Parameter()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'scraped_output'),

    [Parameter()]
    [ValidateRange(1, 20)]
    [int]$RetryCount = 3,

    [Parameter()]
    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 45,

    [Parameter()]
    [ValidateRange(0, 60000)]
    [int]$DelayMilliseconds = 800,

    [Parameter()]
    [string]$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',

    [Parameter()]
    [string]$Proxy,

    [Parameter()]
    [switch]$RenderWithEdge,

    [Parameter()]
    [ValidateRange(1000, 120000)]
    [int]$EdgeRenderMilliseconds = 10000,

    [Parameter()]
    [switch]$SkipCertificateCheck,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$KeepRawHtml
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Net.Http

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string]$Level = 'INFO'
    )

    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'OK'    { 'Green' }
        default { 'Cyan' }
    }
    Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message) -ForegroundColor $color
}

function Read-TextFileAuto {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($bytes)
    }
    catch {
        # AdRadar 导出的 CSV 使用 GB18030（兼容 GBK）。
        return [System.Text.Encoding]::GetEncoding('GB18030').GetString($bytes)
    }
}

function Get-Sha256Short {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$Length = 12
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
        return $hex.Substring(0, [Math]::Min($Length, $hex.Length))
    }
    finally {
        $sha.Dispose()
    }
}

function Get-SafeFileName {
    param(
        [string]$Name,
        [int]$MaxLength = 80
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'unnamed'
    }
    $safe = $Name
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, '_')
    }
    $safe = ($safe -replace '[\x00-\x1F]', '_' -replace '\s+', '_').Trim(' ', '.', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'unnamed'
    }
    if ($safe.Length -gt $MaxLength) {
        $safe = $safe.Substring(0, $MaxLength)
    }
    return $safe
}

function Normalize-LpUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $value = [System.Net.WebUtility]::HtmlDecode($Url.Trim())
    # 广告平台宏在直接访问时没有替换值；给它们稳定的测试值。
    $value = $value.Replace('{placement}', 'vps_scraper').Replace('{creative}', '0')
    $value = $value.Replace(' ', '%20')
    return $value
}

function Convert-BytesToText {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [string]$HeaderCharset
    )

    $charset = $HeaderCharset
    if (-not [string]::IsNullOrWhiteSpace($charset)) {
        $charset = $charset.Trim(' ', '"', "'")
    }

    if ([string]::IsNullOrWhiteSpace($charset)) {
        $previewLength = [Math]::Min($Bytes.Length, 8192)
        $preview = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, $previewLength)
        $match = [regex]::Match(
            $preview,
            '(?is)<meta[^>]+charset\s*=\s*["'']?\s*([a-zA-Z0-9._-]+)|<meta[^>]+content\s*=\s*["''][^"'']*charset\s*=\s*([a-zA-Z0-9._-]+)'
        )
        if ($match.Success) {
            if ($match.Groups[1].Success) { $charset = $match.Groups[1].Value }
            elseif ($match.Groups[2].Success) { $charset = $match.Groups[2].Value }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($charset)) {
        try {
            return [System.Text.Encoding]::GetEncoding($charset).GetString($Bytes)
        }
        catch {
            Write-Log "网页声明了未知编码 '$charset'，改用 UTF-8。" 'WARN'
        }
    }
    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function New-WebClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 10
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $handler.UseCookies = $true
    $handler.CookieContainer = New-Object System.Net.CookieContainer

    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $handler.Proxy = New-Object System.Net.WebProxy($Proxy)
        $handler.UseProxy = $true
    }

    if ($SkipCertificateCheck) {
        $callbackProperty = $handler.PSObject.Properties['ServerCertificateCustomValidationCallback']
        if ($null -ne $callbackProperty) {
            $handler.ServerCertificateCustomValidationCallback = { return $true }
        }
        else {
            Write-Log '当前 PowerShell/.NET 不支持按 HttpClient 跳过证书校验；该参数已忽略。' 'WARN'
        }
    }

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
    $client.DefaultRequestHeaders.AcceptLanguage.ParseAdd('en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7')
    return [PSCustomObject]@{
        Client  = $client
        Handler = $handler
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        [string]$Referer,
        [int]$MaxAttempts = $RetryCount
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $request = $null
        $response = $null
        try {
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            $request.Headers.TryAddWithoutValidation('Accept', $Accept) | Out-Null
            $request.Headers.TryAddWithoutValidation('Cache-Control', 'no-cache') | Out-Null
            if (-not [string]::IsNullOrWhiteSpace($Referer)) {
                $request.Headers.Referrer = New-Object System.Uri($Referer)
            }

            $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            $contentType = ''
            $charset = ''
            if ($null -ne $response.Content.Headers.ContentType) {
                $contentType = [string]$response.Content.Headers.ContentType.MediaType
                $charset = [string]$response.Content.Headers.ContentType.CharSet
            }
            $finalUrl = [string]$response.RequestMessage.RequestUri.AbsoluteUri

            $result = [PSCustomObject]@{
                Success     = ($statusCode -ge 200 -and $statusCode -lt 300)
                StatusCode  = $statusCode
                Reason      = [string]$response.ReasonPhrase
                ContentType = $contentType
                Charset     = $charset
                FinalUrl    = $finalUrl
                Bytes       = $bytes
                Error       = $null
            }

            if ($result.Success -or ($statusCode -ne 408 -and $statusCode -ne 429 -and $statusCode -lt 500)) {
                return $result
            }
            $lastError = "HTTP $statusCode $($response.ReasonPhrase)"
        }
        catch {
            $lastError = $_.Exception.Message
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $request) { $request.Dispose() }
        }

        if ($attempt -lt $MaxAttempts) {
            $waitSeconds = [Math]::Min(30, [Math]::Pow(2, $attempt - 1))
            Write-Log "请求失败，$waitSeconds 秒后重试 ($attempt/$MaxAttempts)：$Url；$lastError" 'WARN'
            Start-Sleep -Seconds $waitSeconds
        }
    }

    return [PSCustomObject]@{
        Success     = $false
        StatusCode  = 0
        Reason      = ''
        ContentType = ''
        Charset     = ''
        FinalUrl    = $Url
        Bytes       = [byte[]]@()
        Error       = $lastError
    }
}

function Get-EdgePath {
    $command = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-RenderedDomWithEdge {
    param(
        [Parameter(Mandatory = $true)][string]$EdgePath,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ProfileDirectory
    )

    New-Item -ItemType Directory -Force -Path $ProfileDirectory | Out-Null
    $escapedProfile = $ProfileDirectory.Replace('"', '\"')
    $escapedUrl = $Url.Replace('"', '%22')
    $arguments = @(
        '--headless=new',
        '--edge-skip-compat-layer-relaunch',
        '--disable-gpu',
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-default-apps',
        '--disable-extensions',
        '--hide-scrollbars',
        '--no-first-run',
        '--no-default-browser-check',
        "--user-data-dir=`"$escapedProfile`"",
        "--virtual-time-budget=$EdgeRenderMilliseconds",
        '--dump-dom',
        "`"$escapedUrl`""
    ) -join ' '

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $EdgePath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($null -ne $startInfo.PSObject.Properties['StandardOutputEncoding']) {
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Edge 进程启动失败。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $processTimeout = [Math]::Max(30000, $EdgeRenderMilliseconds + 30000)
        if (-not $process.WaitForExit($processTimeout)) {
            try { $process.Kill() } catch { }
            throw "Edge 渲染超过 $processTimeout 毫秒。"
        }
        $html = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($html) -or $html -notmatch '(?is)<html|<!doctype') {
            throw "Edge 没有返回有效 HTML。$stderr"
        }
        return [PSCustomObject]@{ Success = $true; Html = $html; Error = $null }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Html = ''; Error = $_.Exception.Message }
    }
    finally {
        $process.Dispose()
    }
}

function Resolve-WebUrl {
    param(
        [Parameter(Mandatory = $true)][System.Uri]$BaseUri,
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
    $value = [System.Net.WebUtility]::HtmlDecode($Candidate.Trim(' ', '"', "'"))
    if ($value.StartsWith('#') -or $value -match '^(?i)(javascript|mailto|tel|blob):') { return $null }
    if ($value.StartsWith('data:', [System.StringComparison]::OrdinalIgnoreCase)) { return $value }

    try {
        return ([System.Uri]::new($BaseUri, $value)).AbsoluteUri
    }
    catch {
        return $null
    }
}

function Get-BaseUri {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$FinalUrl
    )

    $baseUri = [System.Uri]$FinalUrl
    $match = [regex]::Match($Html, '(?is)<base\b[^>]*?\bhref\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^\s>]+))')
    if ($match.Success) {
        $candidate = $match.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[2].Value }
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[3].Value }
        $resolved = Resolve-WebUrl -BaseUri $baseUri -Candidate $candidate
        if (-not [string]::IsNullOrWhiteSpace($resolved) -and $resolved -notmatch '^data:') {
            try { $baseUri = [System.Uri]$resolved } catch { }
        }
    }
    return $baseUri
}

function Get-BalancedHtmlElement {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][int]$StartIndex
    )

    if ($StartIndex -lt 0 -or $StartIndex -ge $Html.Length) { return $null }
    $tail = $Html.Substring($StartIndex)
    $opening = [regex]::Match($tail, '(?is)^<(?<tag>[a-z][a-z0-9:-]*)\b[^>]*>')
    if (-not $opening.Success) { return $null }

    $tagName = $opening.Groups['tag'].Value
    $voidTags = @('area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr')
    if ($opening.Value -match '/\s*>$' -or $tagName -in $voidTags) {
        return [PSCustomObject]@{ Start = $StartIndex; Length = $opening.Length; Html = $opening.Value; Tag = $tagName }
    }

    $escapedTag = [regex]::Escape($tagName)
    $tokens = [regex]::Matches($tail, "(?is)</?$escapedTag\b[^>]*>")
    $depth = 0
    foreach ($token in $tokens) {
        if ($token.Value -match '^<\s*/') {
            $depth--
            if ($depth -eq 0) {
                $length = $token.Index + $token.Length
                return [PSCustomObject]@{
                    Start = $StartIndex
                    Length = $length
                    Html = $Html.Substring($StartIndex, $length)
                    Tag = $tagName
                }
            }
        }
        elseif ($token.Value -notmatch '/\s*>$') {
            $depth++
        }
    }

    return [PSCustomObject]@{ Start = $StartIndex; Length = $opening.Length; Html = $opening.Value; Tag = $tagName }
}

function Get-LongestHtmlElement {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$OpeningPattern,
        [Parameter(Mandatory = $true)][string]$Method
    )

    $best = $null
    $bestTextLength = 0
    foreach ($match in [regex]::Matches($Html, $OpeningPattern)) {
        $element = Get-BalancedHtmlElement -Html $Html -StartIndex $match.Index
        if ($null -eq $element) { continue }
        $plain = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($element.Html, '(?is)<[^>]+>', ' ')))
        $plainLength = ([regex]::Replace($plain, '\s+', ' ')).Trim().Length
        if ($plainLength -gt $bestTextLength) {
            $bestTextLength = $plainLength
            $best = [PSCustomObject]@{ Html = $element.Html; Method = $Method; TextLength = $plainLength }
        }
    }
    return $best
}

function Select-PrimaryContentHtml {
    param([Parameter(Mandatory = $true)][string]$Html)

    $groups = @(
        [PSCustomObject]@{ Method = 'article'; Pattern = '(?is)<article\b[^>]*>' },
        [PSCustomObject]@{
            Method = 'named-content'
            Pattern = '(?is)<(?:div|section)\b[^>]*(?:id|class)\s*=\s*["''][^"'']*(?:article[-_ ]?(?:body|content|wrapper)?|post[-_ ]?content|entry[-_ ]?content|content[-_ ]?body|main[-_ ]?content)[^"'']*["''][^>]*>'
        },
        [PSCustomObject]@{ Method = 'main'; Pattern = '(?is)<main\b[^>]*>' },
        [PSCustomObject]@{ Method = 'body'; Pattern = '(?is)<body\b[^>]*>' }
    )

    foreach ($group in $groups) {
        $candidate = Get-LongestHtmlElement -Html $Html -OpeningPattern $group.Pattern -Method $group.Method
        if ($null -ne $candidate -and $candidate.TextLength -ge 150) { return $candidate }
    }
    return [PSCustomObject]@{ Html = $Html; Method = 'document-fallback'; TextLength = $Html.Length }
}

function Test-IsBlockedContentElement {
    param(
        [Parameter(Mandatory = $true)][string]$OpeningTag,
        [Parameter(Mandatory = $true)][string]$TagName
    )

    if ($TagName -match '^(?i:iframe|object|embed|form|nav|footer)$') { return $true }
    if ($OpeningTag -match '(?i)\bdata-ad(?:-|\s*=)|\bdata-google-query-id\s*=') { return $true }

    $identifiers = New-Object System.Collections.Generic.List[string]
    $attributePattern = '(?is)\b(?:id|class|role|aria-label|data-testid|data-component)\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
    foreach ($attribute in [regex]::Matches($OpeningTag, $attributePattern)) {
        $value = $attribute.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $attribute.Groups[2].Value }
        if (-not [string]::IsNullOrWhiteSpace($value)) { $identifiers.Add($value) }
    }
    if ($identifiers.Count -eq 0) { return $false }

    $identifierText = $identifiers -join ' '
    $blockedIdentifier = '(?i)(?:^|[\s_-])(?:ads?|advert(?:isement|ising)?|adslot|adunit|adsbygoogle|sponsored|promoted|outbrain|taboola|research[\s_-]*topics?|related[\s_-]*(?:search(?:es)?|topics?)|search[\s_-]*(?:topics?|recommendations?)|cookie(?:s|banner)?|consent|cmp|gdpr|social|share(?:[\s_-]*buttons?)?|newsletter|subscribe|breadcrumb|pagination|site[\s_-]*(?:footer|header)|top[\s_-]*bar|navbar)(?:$|[\s_-])'
    return $identifierText -match $blockedIdentifier
}

function Remove-BlockedContentElements {
    param([Parameter(Mandatory = $true)][string]$Html)

    $work = $Html
    $removed = 0
    for ($pass = 0; $pass -lt 500; $pass++) {
        $found = $false
        foreach ($opening in [regex]::Matches($work, '(?is)<(?<tag>[a-z][a-z0-9:-]*)\b[^>]*>')) {
            $tagName = $opening.Groups['tag'].Value
            if (-not (Test-IsBlockedContentElement -OpeningTag $opening.Value -TagName $tagName)) { continue }
            $element = Get-BalancedHtmlElement -Html $work -StartIndex $opening.Index
            if ($null -eq $element) { continue }
            $work = $work.Remove($element.Start, $element.Length)
            $removed++
            $found = $true
            break
        }
        if (-not $found) { break }
    }
    return [PSCustomObject]@{ Html = $work; Removed = $removed }
}

function Remove-SearchRecommendationSections {
    param([Parameter(Mandatory = $true)][string]$Html)

    $work = $Html
    $removed = 0
    $markerPattern = '(?is)>\s*(?:Research\s+topics?|Related\s+search(?:es)?|Sponsored\s+(?:links|results)|Recommended\s+search(?:es)?|People\s+also\s+search)\s*<'
    for ($pass = 0; $pass -lt 100; $pass++) {
        $marker = [regex]::Match($work, $markerPattern)
        if (-not $marker.Success) { break }

        $afterMarker = $work.Substring($marker.Index + $marker.Length)
        $nextContent = [regex]::Match($afterMarker, '(?is)<(?:p|h[2-6])\b[^>]*>')
        if (-not $nextContent.Success -or $nextContent.Index -gt 100000) {
            # 没有可靠的下一段正文/标题时，只移除标签文字，避免误删后续正文。
            $work = $work.Remove($marker.Index, $marker.Length).Insert($marker.Index, '><')
            $removed++
            continue
        }

        $removeStart = $marker.Index
        $beforeMarker = $work.Substring(0, $marker.Index)
        $paragraphMatches = [regex]::Matches($beforeMarker, '(?is)</p\s*>')
        if ($paragraphMatches.Count -gt 0) {
            $lastParagraph = $paragraphMatches[$paragraphMatches.Count - 1]
            if (($marker.Index - ($lastParagraph.Index + $lastParagraph.Length)) -lt 5000) {
                $removeStart = $lastParagraph.Index + $lastParagraph.Length
            }
        }

        $removeEnd = $marker.Index + $marker.Length + $nextContent.Index
        if ($removeEnd -le $removeStart) { break }
        $work = $work.Remove($removeStart, $removeEnd - $removeStart)
        $removed++
    }
    return [PSCustomObject]@{ Html = $work; Removed = $removed }
}

function Get-CleanArticleContent {
    param([Parameter(Mandatory = $true)][string]$Html)

    $selected = Select-PrimaryContentHtml -Html $Html
    $clean = $selected.Html
    $clean = [regex]::Replace($clean, '(?is)<!--.*?-->', ' ')
    $clean = [regex]::Replace($clean, '(?is)<(head|script|style|template|noscript)\b[^>]*>.*?</\1\s*>', ' ')

    $blocked = Remove-BlockedContentElements -Html $clean
    $recommendations = Remove-SearchRecommendationSections -Html $blocked.Html
    return [PSCustomObject]@{
        Html = $recommendations.Html
        Method = $selected.Method
        RemovedBlocks = $blocked.Removed + $recommendations.Removed
    }
}

function Test-IsBlockedResourceUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $true }
    if ($Url.StartsWith('data:', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $blocked = '(?i)(?:doubleclick\.net|googlesyndication\.com|googleadservices\.com|adservice\.google\.|adnxs\.com|adsystem\.com|taboola|outbrain|adsbygoogle|(?:^|[/.?&_-])tracking(?:[/.?&=_-]|$)|(?:^|[/.?&_-])beacon(?:[/.?&=_-]|$)|(?:tracking|conversion|transparent)[_-]?pixel|(?:^|[/.])pixel\.(?:gif|png)(?:[?]|$)|spacer\.(?:gif|png))'
    return $Url -match $blocked
}

function Add-ImageCandidate {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Set,
        [Parameter(Mandatory = $true)][System.Uri]$BaseUri,
        [string]$Candidate
    )

    $resolved = Resolve-WebUrl -BaseUri $BaseUri -Candidate $Candidate
    if (-not [string]::IsNullOrWhiteSpace($resolved) -and -not (Test-IsBlockedResourceUrl -Url $resolved)) {
        $Set.Add($resolved) | Out-Null
    }
}

function Get-ImageCandidatesFromCss {
    param(
        [Parameter(Mandatory = $true)][string]$Css,
        [Parameter(Mandatory = $true)][System.Uri]$BaseUri,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Set
    )

    foreach ($match in [regex]::Matches($Css, '(?is)url\(\s*(?:"([^"]+)"|''([^'']+)''|([^\)]+))\s*\)')) {
        $candidate = $match.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[2].Value }
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[3].Value }
        if ($candidate -match '(?i)\.(?:woff2?|ttf|otf|eot)(?:[?#]|$)') { continue }
        Add-ImageCandidate -Set $Set -BaseUri $BaseUri -Candidate $candidate
    }
}

function Get-ImageCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][System.Uri]$BaseUri,
        [Parameter(Mandatory = $true)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][string]$PageUrl
    )

    $images = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $attributeNames = 'src|data-src|data-original|data-lazy-src|data-lazy|data-image|data-bg|data-background|poster'
    $attributePattern = '(?is)\b(?:' + $attributeNames + ')\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^\s>]+))'
    foreach ($tagMatch in [regex]::Matches($Html, '(?is)<(?:img|input)\b[^>]*>')) {
        foreach ($match in [regex]::Matches($tagMatch.Value, $attributePattern)) {
            $candidate = $match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[2].Value }
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[3].Value }
            Add-ImageCandidate -Set $images -BaseUri $BaseUri -Candidate $candidate
        }
    }

    foreach ($tagMatch in [regex]::Matches($Html, '(?is)<video\b[^>]*>')) {
        $posterMatch = [regex]::Match($tagMatch.Value, '(?is)\bposter\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^\s>]+))')
        if ($posterMatch.Success) {
            $candidate = $posterMatch.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $posterMatch.Groups[2].Value }
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $posterMatch.Groups[3].Value }
            Add-ImageCandidate -Set $images -BaseUri $BaseUri -Candidate $candidate
        }
    }

    $lazyAttributePattern = '(?is)\b(?:data-original|data-lazy-src|data-lazy|data-image|data-bg|data-background)\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^\s>]+))'
    foreach ($match in [regex]::Matches($Html, $lazyAttributePattern)) {
        $candidate = $match.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[2].Value }
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $match.Groups[3].Value }
        Add-ImageCandidate -Set $images -BaseUri $BaseUri -Candidate $candidate
    }

    foreach ($match in [regex]::Matches($Html, '(?is)\b(?:srcset|data-srcset)\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^>]+))')) {
        $srcset = $match.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($srcset)) { $srcset = $match.Groups[2].Value }
        if ([string]::IsNullOrWhiteSpace($srcset)) { $srcset = $match.Groups[3].Value }
        foreach ($item in ($srcset -split ',')) {
            $candidate = ($item.Trim() -split '\s+')[0]
            Add-ImageCandidate -Set $images -BaseUri $BaseUri -Candidate $candidate
        }
    }

    foreach ($match in [regex]::Matches($Html, '(?is)<meta\b[^>]*(?:property|name)\s*=\s*["''](?:og:image|twitter:image(?::src)?)["''][^>]*>')) {
        $contentMatch = [regex]::Match($match.Value, '(?is)\bcontent\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^\s>]+))')
        if ($contentMatch.Success) {
            $candidate = $contentMatch.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $contentMatch.Groups[2].Value }
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $contentMatch.Groups[3].Value }
            Add-ImageCandidate -Set $images -BaseUri $BaseUri -Candidate $candidate
        }
    }

    foreach ($match in [regex]::Matches($Html, '(?is)<link\b[^>]*\brel\s*=\s*["''][^"'']*(?:icon|apple-touch-icon)[^"'']*["''][^>]*>')) {
        $hrefMatch = [regex]::Match($match.Value, '(?is)\bhref\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^\s>]+))')
        if ($hrefMatch.Success) {
            $candidate = $hrefMatch.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $hrefMatch.Groups[2].Value }
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $hrefMatch.Groups[3].Value }
            Add-ImageCandidate -Set $images -BaseUri $BaseUri -Candidate $candidate
        }
    }

    Get-ImageCandidatesFromCss -Css $Html -BaseUri $BaseUri -Set $images

    $stylesheetUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($Html, '(?is)<link\b[^>]*>')) {
        if ($match.Value -notmatch '(?is)\brel\s*=\s*["''][^"'']*stylesheet') { continue }
        $hrefMatch = [regex]::Match($match.Value, '(?is)\bhref\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^\s>]+))')
        if (-not $hrefMatch.Success) { continue }
        $href = $hrefMatch.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($href)) { $href = $hrefMatch.Groups[2].Value }
        if ([string]::IsNullOrWhiteSpace($href)) { $href = $hrefMatch.Groups[3].Value }
        $resolved = Resolve-WebUrl -BaseUri $BaseUri -Candidate $href
        if (-not [string]::IsNullOrWhiteSpace($resolved) -and $resolved -notmatch '^data:') {
            $stylesheetUrls.Add($resolved) | Out-Null
        }
    }

    foreach ($stylesheetUrl in $stylesheetUrls) {
        $cssResponse = Invoke-Download -Client $Client -Url $stylesheetUrl -Accept 'text/css,*/*;q=0.1' -Referer $PageUrl -MaxAttempts 1
        if (-not $cssResponse.Success -or $cssResponse.Bytes.Length -gt 5242880) { continue }
        $css = Convert-BytesToText -Bytes $cssResponse.Bytes -HeaderCharset $cssResponse.Charset
        try { $cssBase = [System.Uri]$cssResponse.FinalUrl } catch { $cssBase = [System.Uri]$stylesheetUrl }
        Get-ImageCandidatesFromCss -Css $css -BaseUri $cssBase -Set $images
    }

    return $images | ForEach-Object { $_ }
}

function Convert-HtmlToText {
    param([Parameter(Mandatory = $true)][string]$Html)

    $text = $Html
    $text = [regex]::Replace($text, '(?is)<!--.*?-->', ' ')
    $text = [regex]::Replace($text, '(?is)<(script|style|svg|template|noscript|head)\b[^>]*>.*?</\1\s*>', ' ')
    $text = [regex]::Replace($text, '(?is)<br\s*/?>|</?(?:p|div|section|article|header|footer|main|aside|nav|h[1-6]|li|ul|ol|table|tr|blockquote|pre|hr)\b[^>]*>', "`n")
    $text = [regex]::Replace($text, '(?is)<[^>]+>', ' ')
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text.Replace([char]0x00A0, ' ')
    $text = [regex]::Replace($text, '[\t\f\v ]+', ' ')
    $text = [regex]::Replace($text, ' *\r?\n *', "`r`n")
    $text = [regex]::Replace($text, '(?:\r?\n){3,}', "`r`n`r`n")
    return $text.Trim()
}

function Get-HtmlTitle {
    param([string]$Html)

    $match = [regex]::Match($Html, '(?is)<title\b[^>]*>(.*?)</title\s*>')
    if (-not $match.Success) { return '' }
    return ([System.Net.WebUtility]::HtmlDecode(([regex]::Replace($match.Groups[1].Value, '<[^>]+>', ' '))) -replace '\s+', ' ').Trim()
}

function Get-ExtensionFromContentType {
    param(
        [string]$ContentType,
        [string]$Url
    )

    $map = @{
        'image/jpeg'    = '.jpg'
        'image/png'     = '.png'
        'image/gif'     = '.gif'
        'image/webp'    = '.webp'
        'image/avif'    = '.avif'
        'image/svg+xml' = '.svg'
        'image/x-icon'  = '.ico'
        'image/vnd.microsoft.icon' = '.ico'
        'image/bmp'     = '.bmp'
        'image/tiff'    = '.tiff'
    }
    if ($map.ContainsKey($ContentType)) { return $map[$ContentType] }

    if (-not [string]::IsNullOrWhiteSpace($Url) -and $Url -notmatch '^data:') {
        try {
            $extension = [System.IO.Path]::GetExtension(([System.Uri]$Url).AbsolutePath).ToLowerInvariant()
            if ($extension -match '^\.(jpe?g|png|gif|webp|avif|svg|ico|bmp|tiff?)$') { return $extension }
        }
        catch { }
    }
    return '.bin'
}

function Save-DataImage {
    param(
        [Parameter(Mandatory = $true)][string]$DataUrl,
        [Parameter(Mandatory = $true)][string]$ImagesDirectory,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $match = [regex]::Match($DataUrl, '^data:(image/[a-zA-Z0-9.+-]+)(;[^,]*)?,(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw '无法识别的 data:image URL。' }
    $contentType = $match.Groups[1].Value.ToLowerInvariant()
    $parameters = $match.Groups[2].Value
    $payload = $match.Groups[3].Value
    if ($parameters -match '(?i);base64') {
        $bytes = [Convert]::FromBase64String($payload)
    }
    else {
        $decoded = [System.Uri]::UnescapeDataString($payload)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($decoded)
    }
    $extension = Get-ExtensionFromContentType -ContentType $contentType -Url $DataUrl
    $fileName = ('{0:D4}_inline{1}' -f $Index, $extension)
    $path = Join-Path $ImagesDirectory $fileName
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return [PSCustomObject]@{ Path = $path; Bytes = $bytes.Length; ContentType = $contentType }
}

function Save-RemoteImages {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ImageUrls,
        [Parameter(Mandatory = $true)][string]$ImagesDirectory,
        [Parameter(Mandatory = $true)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)][string]$Referer,
        [Parameter(Mandatory = $true)][string]$PageDirectory
    )

    if (Test-Path -LiteralPath $ImagesDirectory -PathType Container) {
        Remove-Item -LiteralPath $ImagesDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $ImagesDirectory | Out-Null
    $records = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($imageUrl in $ImageUrls) {
        $index++
        try {
            if ($imageUrl.StartsWith('data:', [System.StringComparison]::OrdinalIgnoreCase)) {
                $saved = Save-DataImage -DataUrl $imageUrl -ImagesDirectory $ImagesDirectory -Index $index
                $records.Add([PSCustomObject]@{
                    index = $index; source_url = '(inline data URI)'; final_url = ''; status = 'ok'
                    http_status = 200; content_type = $saved.ContentType
                    bytes = $saved.Bytes; local_path = 'images/' + [System.IO.Path]::GetFileName($saved.Path); error = ''
                })
                continue
            }

            $response = Invoke-Download -Client $Client -Url $imageUrl -Accept 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8' -Referer $Referer
            if (-not $response.Success) {
                throw "HTTP $($response.StatusCode) $($response.Reason) $($response.Error)"
            }

            $extension = Get-ExtensionFromContentType -ContentType $response.ContentType -Url $response.FinalUrl
            $urlName = ''
            try { $urlName = [System.IO.Path]::GetFileNameWithoutExtension(([System.Uri]$response.FinalUrl).AbsolutePath) } catch { }
            $urlName = Get-SafeFileName -Name $urlName -MaxLength 50
            $fileName = ('{0:D4}_{1}{2}' -f $index, $urlName, $extension)
            $path = Join-Path $ImagesDirectory $fileName
            [System.IO.File]::WriteAllBytes($path, $response.Bytes)
            $relativePath = 'images/' + $fileName
            $records.Add([PSCustomObject]@{
                index = $index; source_url = $imageUrl; final_url = $response.FinalUrl; status = 'ok'
                http_status = $response.StatusCode; content_type = $response.ContentType
                bytes = $response.Bytes.Length; local_path = $relativePath; error = ''
            })
        }
        catch {
            $records.Add([PSCustomObject]@{
                index = $index; source_url = $imageUrl; final_url = ''; status = 'failed'
                http_status = 0; content_type = ''; bytes = 0; local_path = ''; error = $_.Exception.Message
            })
            Write-Log "图片下载失败：$imageUrl；$($_.Exception.Message)" 'WARN'
        }
    }

    $jsonPath = Join-Path $PageDirectory 'images.json'
    $imageJson = if ($records.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $records.ToArray() -Depth 5 }
    [System.IO.File]::WriteAllText($jsonPath, $imageJson, (New-Object System.Text.UTF8Encoding($false)))
    if ($records.Count -gt 0) {
        $records | Export-Csv -LiteralPath (Join-Path $PageDirectory 'images.csv') -NoTypeInformation -Encoding UTF8
    }
    return $records | ForEach-Object { $_ }
}

function Write-JsonUtf8 {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ExistingSuccessfulResult {
    param([string]$ResultPath)

    if ($Force -or -not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) { return $null }
    try {
        $existing = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # 旧版结果可能包含导航、推荐搜索或广告素材，必须由新版重新清洗。
        if ($existing.status -eq 'ok' -and $existing.advertising_filtered -eq $true) { return $existing }
    }
    catch { }
    return $null
}

try {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

    if ($CsvPath.Count -eq 0) {
        $CsvPath = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.csv' | Select-Object -ExpandProperty FullName)
    }
    if ($CsvPath.Count -eq 0) {
        throw "没有找到 CSV。请把 CSV 放到脚本目录，或通过 -CsvPath 指定文件。"
    }

    $urlRecords = @{}
    foreach ($csv in $CsvPath) {
        $resolvedCsv = (Resolve-Path -LiteralPath $csv).Path
        Write-Log "读取 CSV：$resolvedCsv"
        $csvText = Read-TextFileAuto -Path $resolvedCsv
        $rows = @($csvText | ConvertFrom-Csv)
        if ($rows.Count -eq 0) {
            Write-Log "CSV 没有数据行：$resolvedCsv" 'WARN'
            continue
        }

        $lpColumn = $rows[0].PSObject.Properties | Where-Object { $_.Name.Trim() -ieq 'LP URL' } | Select-Object -First 1
        if ($null -eq $lpColumn) {
            throw "CSV 缺少 'LP URL' 字段：$resolvedCsv"
        }

        for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
            $rawUrl = [string]$rows[$rowIndex].($lpColumn.Name)
            if ([string]::IsNullOrWhiteSpace($rawUrl)) { continue }
            $normalizedUrl = Normalize-LpUrl -Url $rawUrl
            try {
                $uri = [System.Uri]$normalizedUrl
                if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https')) { throw '不是 HTTP(S) 绝对地址。' }
            }
            catch {
                Write-Log "忽略无效 LP URL（$([System.IO.Path]::GetFileName($resolvedCsv)) 第 $($rowIndex + 2) 行）：$rawUrl" 'WARN'
                continue
            }

            if (-not $urlRecords.ContainsKey($normalizedUrl)) {
                $urlRecords[$normalizedUrl] = New-Object System.Collections.Generic.List[object]
            }
            $urlRecords[$normalizedUrl].Add([PSCustomObject]@{
                csv = [System.IO.Path]::GetFileName($resolvedCsv)
                row = $rowIndex + 2
                original_url = $rawUrl
            })
        }
    }

    if ($urlRecords.Count -eq 0) { throw 'CSV 中没有可用的 LP URL。' }
    Write-Log "共发现 $($urlRecords.Count) 个去重后的 LP URL。" 'OK'

    $edgePath = $null
    $edgeProfile = Join-Path $resolvedOutput '_edge_profile'
    if ($RenderWithEdge) {
        $edgePath = Get-EdgePath
        if ([string]::IsNullOrWhiteSpace($edgePath)) {
            throw '指定了 -RenderWithEdge，但没有找到 Microsoft Edge。请安装 Edge 或去掉该参数。'
        }
        Write-Log "使用 Edge 动态渲染：$edgePath"
    }

    $webClientBundle = New-WebClient
    $client = $webClientBundle.Client
    $handler = $webClientBundle.Handler
    $summary = New-Object System.Collections.Generic.List[object]
    $current = 0

    try {
        foreach ($entry in ($urlRecords.GetEnumerator() | Sort-Object Name)) {
            $current++
            $url = [string]$entry.Key
            $sources = $entry.Value.ToArray()
            $uri = [System.Uri]$url
            $hostDirectory = Join-Path $resolvedOutput (Get-SafeFileName -Name $uri.DnsSafeHost -MaxLength 100)
            $pageDirectory = Join-Path $hostDirectory (Get-Sha256Short -Text $url)
            $resultPath = Join-Path $pageDirectory 'result.json'
            New-Item -ItemType Directory -Force -Path $pageDirectory | Out-Null

            $existing = Get-ExistingSuccessfulResult -ResultPath $resultPath
            if ($null -ne $existing) {
                Write-Log "[$current/$($urlRecords.Count)] 已完成，跳过：$url" 'OK'
                $summary.Add([PSCustomObject]@{
                    status = 'skipped'; http_status = $existing.http_status; title = $existing.title
                    url = $url; final_url = $existing.final_url; directory = $pageDirectory
                    content_scope = $existing.content_scope; filtered_blocks = $existing.removed_non_content_blocks
                    image_count = $existing.image_count; failed_images = $existing.failed_images; error = ''
                })
                continue
            }

            Write-Log "[$current/$($urlRecords.Count)] 抓取：$url"
            $startedAt = Get-Date
            $response = Invoke-Download -Client $client -Url $url
            $html = ''
            $sourceHtml = ''
            $renderedWithEdge = $false
            $renderError = ''

            foreach ($rawName in @('page.source.html', 'page.rendered.raw.html')) {
                $rawPath = Join-Path $pageDirectory $rawName
                if (-not $KeepRawHtml -and (Test-Path -LiteralPath $rawPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $rawPath -Force
                }
            }

            if ($response.Bytes.Length -gt 0) {
                $sourceHtml = Convert-BytesToText -Bytes $response.Bytes -HeaderCharset $response.Charset
                if ($KeepRawHtml) {
                    [System.IO.File]::WriteAllText((Join-Path $pageDirectory 'page.source.html'), $sourceHtml, (New-Object System.Text.UTF8Encoding($false)))
                }
                $html = $sourceHtml
            }

            if ($RenderWithEdge) {
                $render = Get-RenderedDomWithEdge -EdgePath $edgePath -Url $url -ProfileDirectory $edgeProfile
                if ($render.Success) {
                    $html = $render.Html
                    $renderedWithEdge = $true
                    if ($KeepRawHtml) {
                        [System.IO.File]::WriteAllText((Join-Path $pageDirectory 'page.rendered.raw.html'), $html, (New-Object System.Text.UTF8Encoding($false)))
                    }
                }
                else {
                    $renderError = $render.Error
                    Write-Log "Edge 渲染失败，保留 HTTP 原始内容：$renderError" 'WARN'
                }
            }

            $pageSuccess = -not [string]::IsNullOrWhiteSpace($html) -and ($response.Success -or $renderedWithEdge)
            $title = ''
            $imageRecords = @()
            $contentMethod = ''
            $removedBlockCount = 0
            if (-not [string]::IsNullOrWhiteSpace($html)) {
                $title = Get-HtmlTitle -Html $html
                $baseUrl = $response.FinalUrl
                if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = $url }
                $baseUri = Get-BaseUri -Html $html -FinalUrl $baseUrl

                $cleanContent = Get-CleanArticleContent -Html $html
                $articleHtml = $cleanContent.Html
                $contentMethod = $cleanContent.Method
                $removedBlockCount = $cleanContent.RemovedBlocks
                $encodedTitle = [System.Net.WebUtility]::HtmlEncode($title)
                $encodedBaseUrl = [System.Net.WebUtility]::HtmlEncode($baseUrl)
                $cleanDocument = "<!doctype html><html><head><meta charset=`"utf-8`"><title>$encodedTitle</title><base href=`"$encodedBaseUrl`"></head><body>$articleHtml</body></html>"
                [System.IO.File]::WriteAllText((Join-Path $pageDirectory 'page.html'), $cleanDocument, (New-Object System.Text.UTF8Encoding($false)))

                $textContent = Convert-HtmlToText -Html $articleHtml
                [System.IO.File]::WriteAllText((Join-Path $pageDirectory 'text.txt'), $textContent, (New-Object System.Text.UTF8Encoding($false)))

                $imageUrls = @(Get-ImageCandidates -Html $articleHtml -BaseUri $baseUri -Client $client -PageUrl $baseUrl)
                Write-Log "正文范围：$contentMethod；已过滤 $removedBlockCount 个广告/非正文区块；发现 $($imageUrls.Count) 张正文图片。"
                $imageRecords = @(Save-RemoteImages -ImageUrls $imageUrls -ImagesDirectory (Join-Path $pageDirectory 'images') -Client $client -Referer $baseUrl -PageDirectory $pageDirectory)
            }

            $failedImageCount = @($imageRecords | Where-Object { $_.status -eq 'failed' }).Count
            $result = [PSCustomObject]@{
                scraper_version = 2
                status = $(if ($pageSuccess) { 'ok' } else { 'failed' })
                requested_url = $url
                final_url = $response.FinalUrl
                http_status = $response.StatusCode
                http_reason = $response.Reason
                content_type = $response.ContentType
                title = $title
                rendered_with_edge = $renderedWithEdge
                render_error = $renderError
                advertising_filtered = $true
                content_scope = $contentMethod
                removed_non_content_blocks = $removedBlockCount
                raw_html_saved = [bool]$KeepRawHtml
                image_count = $imageRecords.Count
                failed_images = $failedImageCount
                started_at = $startedAt.ToString('o')
                finished_at = (Get-Date).ToString('o')
                sources = $sources
                error = $response.Error
            }
            Write-JsonUtf8 -Value $result -Path $resultPath

            $summary.Add([PSCustomObject]@{
                status = $result.status; http_status = $result.http_status; title = $title
                url = $url; final_url = $response.FinalUrl; directory = $pageDirectory
                content_scope = $contentMethod; filtered_blocks = $removedBlockCount
                image_count = $result.image_count; failed_images = $failedImageCount; error = $result.error
            })

            if ($pageSuccess) {
                Write-Log "完成：$title（图片 $($imageRecords.Count)，失败 $failedImageCount）" 'OK'
            }
            else {
                Write-Log "页面抓取失败：HTTP $($response.StatusCode) $($response.Error)" 'ERROR'
            }

            if ($DelayMilliseconds -gt 0 -and $current -lt $urlRecords.Count) {
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }

    $summaryPath = Join-Path $resolvedOutput 'summary.csv'
    $summary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8
    Write-JsonUtf8 -Value $summary.ToArray() -Path (Join-Path $resolvedOutput 'summary.json')
    $okCount = @($summary | Where-Object { $_.status -in @('ok', 'skipped') }).Count
    $failedCount = @($summary | Where-Object { $_.status -eq 'failed' }).Count
    Write-Log "全部结束：成功/已跳过 $okCount，失败 $failedCount。汇总：$summaryPath" $(if ($failedCount -eq 0) { 'OK' } else { 'WARN' })

    if ($failedCount -gt 0) { exit 2 }
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Log $_.ScriptStackTrace 'ERROR'
    }
    exit 1
}
