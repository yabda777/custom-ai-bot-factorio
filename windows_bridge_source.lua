-- PowerShell source copied as text in the pairing prompt.
return [==[
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$EnableClipboard,
    [string]$GameConfig = (Join-Path $env:APPDATA 'Factorio\config\config.ini')
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$identityFile = "$PSCommandPath.identity"
$GameConfig = [IO.Path]::GetFullPath($GameConfig)

function New-Secret {
    $bytes = [byte[]]::new(32)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Get-GameSettings {
    if (!(Test-Path -LiteralPath $GameConfig -PathType Leaf)) {
        throw 'Factorio config.ini is missing. Start Factorio once and close it, or pass -GameConfig.'
    }
    $configText = [IO.File]::ReadAllText($GameConfig)
    $section = [regex]::Match($configText, '(?ms)^\[other\][^\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)')
    if (!$section.Success) { throw 'Factorio config.ini has no [other] section.' }
    $body = $section.Groups['body']
    $socket = [regex]::Match($body.Value, '(?m)^\s*local-rcon-socket[ \t]*=[ \t]*([^\r\n]*)').Groups[1].Value.Trim()
    $secret = [regex]::Match($body.Value, '(?m)^\s*local-rcon-password[ \t]*=[ \t]*([^\r\n]*)').Groups[1].Value.Trim()
    return @{ Text=$configText; Body=$body; Socket=$socket; Password=$secret }
}

function Enable-LocalRcon {
    $settings = Get-GameSettings
    if ($settings.Socket -and $settings.Socket -notmatch '^127\.0\.0\.1:\d+$' -and $settings.Socket -ne '0.0.0.0:0') {
        throw 'Factorio already has a non-loopback RCON address. Choose a local configuration before pairing.'
    }
    if ($settings.Socket -match '^127\.0\.0\.1:[1-9]\d*$' -and $settings.Password) { return }
    if (Get-Process -Name factorio -ErrorAction SilentlyContinue) {
        throw 'Save and exit Factorio before enabling RCON. Then rerun setup and host the save again.'
    }
    $newline = if ($settings.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $body = [regex]::Replace($settings.Body.Value, '(?m)^[ \t]*local-rcon-(socket|password)[ \t]*=[^\r\n]*\r?\n?', '')
    $lines = "local-rcon-socket=127.0.0.1:27085$newline" + "local-rcon-password=$(New-Secret)$newline"
    $updated = $settings.Text.Remove($settings.Body.Index, $settings.Body.Length).Insert($settings.Body.Index, $lines + $body)
    $backup = "$GameConfig.sam-backup"
    if (!(Test-Path -LiteralPath $backup)) { [IO.File]::Copy($GameConfig, $backup) }
    $temporary = "$GameConfig.sam-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $updated, $utf8)
        [IO.File]::Replace($temporary, $GameConfig, "$temporary.previous")
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists("$temporary.previous")) { [IO.File]::Delete("$temporary.previous") }
    }
}

if ($Setup) {
    Enable-LocalRcon
    $command = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','RemoteSigned','-File',$PSCommandPath,'-GameConfig',$GameConfig,'-EnableClipboard')
    '[mcp_servers.sam_engineer]'
    'command = ' + (ConvertTo-Json -Compress -InputObject $command)
    'args = ' + (ConvertTo-Json -Compress -InputObject $arguments)
    return
}

function Start-ClipboardWatcher {
    $config = [IO.File]::ReadAllText($GameConfig)
    $writeData = [regex]::Match($config, '(?m)^[ \t]*write-data[ \t]*=[ \t]*([^\r\n]*)').Groups[1].Value.Trim()
    if (!$writeData -or $writeData -eq '__PATH__system-write-data__') {
        $writeData = Join-Path $env:APPDATA 'Factorio'
    }
    if (![IO.Path]::IsPathRooted($writeData)) { throw 'Clipboard sharing requires an absolute Factorio write-data path.' }
    $file = Join-Path $writeData 'script-output\sam-engineer\clipboard.txt'
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $watcher = [powershell]::Create()
    $watcher.Runspace = $runspace
    [void]$watcher.AddScript({
        param($Path, $LastWrite)
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        while ($true) {
            Start-Sleep -Milliseconds 250
            try {
                $file = [IO.FileInfo]::new($Path)
                if (!$file.Exists -or $file.LastWriteTimeUtc -le $LastWrite -or $file.Length -gt 16384) { continue }
                $draft = [IO.File]::ReadAllText($Path)
                if ($draft -notmatch '"pairing_code"\s*:\s*"\d{8}"' -or !$draft.Contains('sam_engineer')) { continue }
                [Windows.Forms.Clipboard]::SetDataObject($draft, $true, 3, 50)
                $LastWrite = $file.LastWriteTimeUtc
            } catch [IO.IOException] {
                # Factorio may still be writing the file.
            } catch [Runtime.InteropServices.ExternalException] {
                # Another desktop application may have the clipboard open.
            }
        }
    }).AddArgument($file).AddArgument([DateTime]::UtcNow)
    [void]$watcher.BeginInvoke()
    return $watcher
}

function Send-RconPacket($Stream, [int]$Id, [int]$Kind, [string]$Body) {
    $bytes = $utf8.GetBytes($Body)
    $writer = [IO.BinaryWriter]::new($Stream, $utf8, $true)
    try {
        $writer.Write([int]($bytes.Length + 10))
        $writer.Write($Id)
        $writer.Write($Kind)
        $writer.Write($bytes)
        $writer.Write([uint16]0)
        $writer.Flush()
    } finally { $writer.Dispose() }
}

function Read-RconPacket($Reader) {
    $length = $Reader.ReadInt32()
    if ($length -lt 10 -or $length -gt 4000000) { throw 'Invalid RCON packet length.' }
    $packet = $Reader.ReadBytes($length)
    if ($packet.Length -ne $length -or $packet[$length-2] -ne 0 -or $packet[$length-1] -ne 0) {
        throw 'Incomplete RCON packet.'
    }
    return @{
        Id=[BitConverter]::ToInt32($packet,0)
        Kind=[BitConverter]::ToInt32($packet,4)
        Body=$utf8.GetString($packet,8,$length-10)
    }
}

function Invoke-Factorio([string]$Method, $Arguments) {
    $settings = Get-GameSettings
    if ($settings.Socket -notmatch '^127\.0\.0\.1:([1-9]\d{0,4})$' -or !$settings.Password) {
        throw 'Local RCON is disabled. Run the bundled script with -Setup before hosting the game.'
    }
    $port = [int]$Matches[1]
    if (!(Test-Path -LiteralPath $identityFile -PathType Leaf)) {
        $file = $null
        try {
            $file = [IO.File]::Open($identityFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            $secret = $utf8.GetBytes((New-Secret))
            $file.Write($secret,0,$secret.Length)
        } catch [IO.IOException] {
            if (![IO.File]::Exists($identityFile)) { throw }
        } finally {
            if ($file) { $file.Dispose() }
        }
    }
    $request = ConvertTo-Json -Compress -Depth 12 -InputObject @{
        method=$Method; args=$Arguments; token=[IO.File]::ReadAllText($identityFile)
    }
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        try {
            if (!$tcp.ConnectAsync('127.0.0.1',$port).Wait(3000)) { throw 'Connection timed out.' }
        } catch { throw 'Cannot connect to local Factorio. Host a multiplayer game from the Factorio menu.' }
        $tcp.ReceiveTimeout = 8000
        $stream = $tcp.GetStream()
        $reader = [IO.BinaryReader]::new($stream, $utf8, $true)
        try {
            Send-RconPacket $stream 1 3 $settings.Password
            $authenticated = $false
            for ($i=0; $i -lt 4; $i++) {
                $packet = Read-RconPacket $reader
                if ($packet.Id -eq -1) { throw 'Factorio rejected the local RCON password.' }
                if ($packet.Id -eq 1 -and $packet.Kind -eq 2) { $authenticated = $true; break }
            }
            if (!$authenticated) { throw 'No Factorio RCON authentication response.' }
            Send-RconPacket $stream 2 2 "/sam-ai-rcon $request"
            for ($i=0; $i -lt 4; $i++) {
                $packet = Read-RconPacket $reader
                if ($packet.Id -ne 2 -or $packet.Kind -ne 0) { continue }
                $responsePrefix = 'SAM '
                foreach ($line in $packet.Body -split '\r?\n') {
                    if (!$line.StartsWith($responsePrefix)) { continue }
                    $reply = ConvertFrom-Json $line.Substring($responsePrefix.Length)
                    if (!$reply.ok) { throw $reply.error }
                    return $reply.result
                }
                throw 'The running map did not answer. Enable the matching Custom AI Bot (ChatGPT-Codex) mod.'
            }
            throw 'No Factorio RCON reply.'
        } finally { $reader.Dispose() }
    } finally { $tcp.Dispose() }
}

function New-Tool($Name, $Description, $Properties, $Required = @()) {
    return @{
        name=$Name; description=$Description
        inputSchema=@{type='object'; properties=$Properties; required=@($Required); additionalProperties=$false}
    }
}

$tools = @(
    (New-Tool 'pair' 'Pair using the eight-digit code from the Companion panel.' @{code=@{type='string';pattern='^\d{8}$'}} @('code'))
    (New-Tool 'status' 'Read the engineer location, inventory and current plan.' @{})
    (New-Tool 'come_here' 'Ask the engineer to walk to the paired player.' @{})
    (New-Tool 'mine' 'Ask the engineer to mine a supported resource nearby.' @{
        resource=@{type='string';enum=@('stone','coal','iron-ore','copper-ore')}
        count=@{type='integer';minimum=1;maximum=100}
    } @('resource','count'))
    (New-Tool 'job_status' 'Check a queued task by ID. Confirm completion from its result.' @{id=@{type='integer';minimum=1}} @('id'))
)

$reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8)
$writer = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $utf8)
$writer.AutoFlush = $true
$clipboardWatcher = $null
if ($EnableClipboard) {
    try { $clipboardWatcher = Start-ClipboardWatcher }
    catch { [Console]::Error.WriteLine($_.Exception.Message) }
}
while ($null -ne ($line = $reader.ReadLine())) {
    $request = $null
    $reply = @{jsonrpc='2.0';id=$null}
    try {
        $request = ConvertFrom-Json $line
        if (!$request.PSObject.Properties['id']) { continue }
        $reply.id = $request.id
        switch -CaseSensitive ($request.method) {
            'initialize' {
                $version = $request.params.protocolVersion
                if ($version -notin @('2024-11-05','2025-03-26','2025-06-18','2025-11-25')) { $version='2024-11-05' }
                $reply.result = @{protocolVersion=$version;serverInfo=@{name='sam_engineer';version='1.1.4'}
                    capabilities=@{tools=@{}};instructions='Use pair once per world and check job_status before reporting completion.'}
            }
            'ping' { $reply.result=@{} }
            'tools/list' { $reply.result=@{tools=$tools} }
            'tools/call' {
                try {
                    $method = $request.params.name
                    if ($method -cnotin $tools.name) { throw 'Unknown tool.' }
                    $result = Invoke-Factorio $method $request.params.arguments
                    $reply.result=@{content=@(@{type='text';text=(ConvertTo-Json -InputObject $result -Depth 30 -Compress)})}
                } catch {
                    $reply.result=@{isError=$true;content=@(@{type='text';text=$_.Exception.Message})}
                }
            }
            default { $reply.error=@{code=-32601;message='Method not found'} }
        }
    } catch {
        $reply.error=@{code=-32700;message='Invalid JSON-RPC message'}
    }
    $writer.WriteLine((ConvertTo-Json -InputObject $reply -Depth 30 -Compress))
}
if ($clipboardWatcher) {
    $runspace = $clipboardWatcher.Runspace
    $clipboardWatcher.Stop()
    $clipboardWatcher.Dispose()
    $runspace.Dispose()
}
]==]
