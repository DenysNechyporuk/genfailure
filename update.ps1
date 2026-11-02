# Pulls I AM FROM TEL#AVIV's rank and recent games into data.js.
# With a Riot API key in riot-key.txt it uses the Riot API; otherwise (or if that fails) it reads op.gg.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$gameName   = "I AM FROM TEL"
$tagLine    = "AVIV"
$platform   = "https://euw1.api.riotgames.com"
$region     = "https://europe.api.riotgames.com"
$opggUrl    = "https://op.gg/lol/summoners/euw/$([uri]::EscapeDataString($gameName))-$([uri]::EscapeDataString($tagLine))"
$matchCount = 20

$keyFile = Join-Path $PSScriptRoot "riot-key.txt"
$outFile = Join-Path $PSScriptRoot "data.js"

$romans   = @{ "I" = 1; "II" = 2; "III" = 3; "IV" = 4 }
$textInfo = (Get-Culture).TextInfo

function Format-Tier($tier, $division) {
    $name = $textInfo.ToTitleCase($tier.ToLower())
    # Master and above have no division
    if ($division -and $tier -notin "MASTER", "GRANDMASTER", "CHALLENGER") { $name += " $division" }
    $name
}

# Champion display names, icon IDs and icon version come from Data Dragon
try {
    $version = (Invoke-RestMethod "https://ddragon.leagueoflegends.com/api/versions.json")[0]
    $champs  = (Invoke-RestMethod "https://ddragon.leagueoflegends.com/cdn/$version/data/en_US/champion.json").data
}
catch {
    Write-Host "Couldn't reach Riot's Data Dragon: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "The page will show the last saved data." -ForegroundColor Yellow
    exit 1
}
$idByName = @{}
foreach ($c in $champs.PSObject.Properties.Value) { $idByName[$c.name] = $c.id }

function Get-FromRiot {
    $headers = @{ "X-Riot-Token" = (Get-Content $keyFile -Raw).Trim() }
    function Get-Riot($url) { Invoke-RestMethod -Uri $url -Headers $headers }

    $queues = @{ 420 = "Solo/Duo"; 440 = "Flex"; 400 = "Normal"; 430 = "Normal"; 490 = "Normal"; 450 = "ARAM"; 1700 = "Arena"; 900 = "URF"; 1900 = "URF" }

    $account = Get-Riot "$region/riot/account/v1/accounts/by-riot-id/$([uri]::EscapeDataString($gameName))/$([uri]::EscapeDataString($tagLine))"
    $puuid   = $account.puuid
    $entries = @(Get-Riot "$platform/lol/league/v4/entries/by-puuid/$puuid")
    $ids     = @(Get-Riot "$region/lol/match/v5/matches/by-puuid/$puuid/ids?count=$matchCount")

    $games = @()
    foreach ($id in $ids) {
        $info = (Get-Riot "$region/lol/match/v5/matches/$id").info
        $me   = $info.participants | Where-Object { $_.puuid -eq $puuid }
        $name = $champs.($me.championName).name
        $queue = $queues[[int]$info.queueId]
        $games += [ordered]@{
            id       = $me.championName
            name     = $(if ($name) { $name } else { $me.championName })
            win      = [bool]$me.win
            k        = $me.kills
            d        = $me.deaths
            a        = $me.assists
            cs       = $me.totalMinionsKilled + $me.neutralMinionsKilled
            queue    = $(if ($queue) { $queue } else { "Other" })
            duration = $info.gameDuration
            ended    = $info.gameEndTimestamp
            when     = $null
        }
        # Stay under the development key's 20 requests per second
        Start-Sleep -Milliseconds 60
    }

    $solo = $entries | Where-Object { $_.queueType -eq "RANKED_SOLO_5x5" }
    $flex = $entries | Where-Object { $_.queueType -eq "RANKED_FLEX_SR" }
    [ordered]@{
        source = "Riot API"
        solo   = $(if ($solo) { [ordered]@{ tier = Format-Tier $solo.tier $romans[$solo.rank]; lp = $solo.leaguePoints; wins = $solo.wins; losses = $solo.losses } })
        flex   = $(if ($flex) { [ordered]@{ tier = Format-Tier $flex.tier $romans[$flex.rank]; lp = $flex.leaguePoints; wins = $flex.wins; losses = $flex.losses } })
        games  = $games
    }
}

# op.gg embeds a schema.org JSON-LD block on the profile page with the solo rank and the last 10 games
function Get-FromOpgg {
    $response = Invoke-WebRequest -Uri $opggUrl -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
    $html = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    $match = [regex]::Match($html, '<script[^>]*application/ld\+json[^>]*>([\s\S]*?)</script>')
    if (-not $match.Success) { throw "op.gg page has no JSON-LD block (the site may have changed)" }
    $graph = ($match.Groups[1].Value | ConvertFrom-Json).'@graph'

    # Rank only appears in the description, e.g. "rank is silver 1 Division 1 32 LP with 261 wins, 255 losses"
    $profile = $graph | Where-Object { $_.'@type' -eq 'ProfilePage' }
    $solo = $null
    $rank = [regex]::Match($profile.description, 'SOLORANKED rank is (\w+)(?: (\d))?(?: Division \d)? (\d+) LP with (\d+) wins, (\d+) losses')
    if ($rank.Success) {
        $solo = [ordered]@{
            tier   = Format-Tier $rank.Groups[1].Value.ToUpper() $rank.Groups[2].Value
            lp     = [int]$rank.Groups[3].Value
            wins   = [int]$rank.Groups[4].Value
            losses = [int]$rank.Groups[5].Value
        }
    }

    $queues = @{ SOLORANKED = "Solo/Duo"; FLEXRANKED = "Flex"; NORMAL = "Normal"; ARAM = "ARAM"; ARENA = "Arena"; URF = "URF" }
    $recent = $graph | Where-Object { $_.'@type' -eq 'ItemList' }
    $games = @()
    foreach ($item in $recent.itemListElement) {
        $props = @{}
        foreach ($prop in $item.item.additionalProperty) { $props[$prop.name] = $prop.value }
        # Remakes aren't real games
        if ($props.result -notin "WIN", "LOSE") { continue }
        $id = $idByName[$props.champion]
        $queue = $queues[$props.queueType]
        $games += [ordered]@{
            id       = $(if ($id) { $id } else { $props.champion -replace '[^A-Za-z]', '' })
            name     = $props.champion
            win      = $props.result -eq "WIN"
            k        = $props.kills
            d        = $props.deaths
            a        = $props.assists
            cs       = $props.cs
            queue    = $(if ($queue) { $queue } else { $textInfo.ToTitleCase("$($props.queueType)".ToLower()) })
            duration = $null
            ended    = [DateTimeOffset]::Parse($item.item.startTime).ToUnixTimeMilliseconds()
            when     = $null
        }
    }
    if ($games.Count -eq 0 -and -not $solo) { throw "op.gg returned no rank or games (the site may have changed)" }

    [ordered]@{ source = "op.gg"; solo = $solo; flex = $null; games = $games }
}

function Show-Failure($what, $err) {
    $status = $null
    if ($err.Exception.Response) { $status = [int]$err.Exception.Response.StatusCode }
    $reason = switch ($status) {
        { $_ -in 401, 403 } { "access denied (Riot key invalid or expired?)" }
        404     { "couldn't find $gameName#$tagLine" }
        429     { "rate limited - try again in a couple of minutes" }
        default { $err.Exception.Message }
    }
    Write-Host "$what failed: $reason" -ForegroundColor Red
}

$data = $null
if (Test-Path $keyFile) {
    Write-Host "Fetching $gameName#$tagLine from the Riot API..."
    try { $data = Get-FromRiot } catch { Show-Failure "Riot API" $_ }
}
if (-not $data) {
    Write-Host "Fetching $gameName#$tagLine from op.gg..."
    try { $data = Get-FromOpgg } catch { Show-Failure "op.gg" $_ }
}
if (-not $data) {
    Write-Host "The page will show the last saved data." -ForegroundColor Yellow
    exit 1
}

$data = [ordered]@{
    updated = (Get-Date).ToString("s")
    source  = $data.source
    ddragon = $version
    solo    = $data.solo
    flex    = $data.flex
    games   = $data.games
}
$json = ConvertTo-Json -InputObject $data -Depth 5
$js = "// Overwritten by update.ps1 each time open.bat runs.`nwindow.PLAYER_DATA = $json;`n"
[IO.File]::WriteAllText($outFile, $js, (New-Object Text.UTF8Encoding $false))
Write-Host "Updated from $($data.source) with $($data.games.Count) games." -ForegroundColor Green
