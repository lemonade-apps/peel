<#
    .SYNOPSIS
    This file contains the cmdlets for the PEEL (PowerShell Enhanced by Embedded Lemonade) module.
    
    Contains the implementation of Install-Lemonade, Get-Aid, Get-MoreAid, and Get-MaximumAid
#>

# --- PEEL shell detection logic ---
if ($env:PEEL_SHELL) {
    $global:PEEL_SHELL = $true
}
# --- end PEEL shell detection logic ---

# --- PEEL transcript logic ---
# Only start transcript if running in a PEEL shell
if ($env:PEEL_SHELL) {
    $global:PEELTranscriptPath = Join-Path $env:TEMP ("peel_transcript_" + $PID + "_" + [guid]::NewGuid().ToString() + ".txt")
    try {
        if (-not (Get-Variable -Name TranscriptEnabled -Scope Global -ErrorAction SilentlyContinue)) {
            $global:TranscriptEnabled = $false
        }
        if (-not $global:TranscriptEnabled) {
            Start-Transcript -Path $global:PEELTranscriptPath | Out-Null
            $global:TranscriptEnabled = $true
        }
    } catch {
        Write-Warning "Could not start transcript: $($_.Exception.Message)"
    }
}
# --- end transcript logic ---

# --- PEEL transparent external command capture ---
if ($env:PEEL_SHELL) {
    if (-not (Test-Path function:\OriginalPrompt)) {
        function OriginalPrompt { & $function:prompt }
        Set-Alias -Name peel_original_prompt -Value OriginalPrompt -Scope Global
    }
    function prompt {
        $line = Read-Host -Prompt (peel_original_prompt)
        if ([string]::IsNullOrWhiteSpace($line)) { return (peel_original_prompt) }
        $parsed = $null
        try {
            $parsed = [System.Management.Automation.PSParser]::Tokenize($line, [ref]$null)
        } catch {}
        $firstToken = $parsed | Where-Object { $_.Type -eq 'Command' } | Select-Object -First 1
        $cmd = $firstToken.Content
        $isInternal = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($isInternal -and $isInternal.CommandType -ne 'Application') {
            # PowerShell cmdlet/function/alias: invoke normally
            Invoke-Expression $line
        } else {
            # External command: capture output
            $args = $line.Substring($cmd.Length).Trim()
            if ($args) {
                Invoke-PEELCommand -Command $cmd -Arguments $args.Split(' ')
            } else {
                Invoke-PEELCommand -Command $cmd
            }
        }
        return (peel_original_prompt)
    }
}
# --- end PEEL transparent external command capture ---

function Invoke-PEELCommand {
    <#
        .SYNOPSIS
        Runs an external command, capturing both stdout and stderr to the PEEL transcript and displaying output in real time.
        .DESCRIPTION
        Use this function to run external programs (e.g., python, node, etc.) so their output is included in the PEEL transcript for LLM assistance.
        .PARAMETER Command
        The command to run (as a string or array).
        .PARAMETER Arguments
        Arguments to pass to the command (optional).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Command,
        [Parameter(Position=1)]
        [string[]]$Arguments
    )
    if (-not $global:PEELTranscriptPath) {
        Write-Error "PEEL transcript not active. Only use Invoke-PEELCommand in a PEEL shell."
        return
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    if ($Arguments) {
        $psi.Arguments = [string]::Join(' ', $Arguments)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()
    $stdout = $process.StandardOutput
    $stderr = $process.StandardError
    while (-not $stdout.EndOfStream -or -not $stderr.EndOfStream) {
        if (-not $stdout.EndOfStream) {
            $line = $stdout.ReadLine()
            Write-Host $line
            Add-Content -Path $global:PEELTranscriptPath -Value $line
        }
        if (-not $stderr.EndOfStream) {
            $errLine = $stderr.ReadLine()
            Write-Host $errLine -ForegroundColor Red
            Add-Content -Path $global:PEELTranscriptPath -Value $errLine
        }
    }
    $process.WaitForExit()
    return $process.ExitCode
}

function Install-Lemonade {
    <#
        .SYNOPSIS
        Downloads and executes the latest Lemonade Server Installer.

        .DESCRIPTION
        This cmdlet downloads the Lemonade Server Installer from the official TurnkeyML GitHub releases page
        and executes it. It handles scenarios where the installer is already present, the download fails,
        or the installer execution fails.
    #>
    [CmdletBinding()]
    param()

    $installerUrl = "https://github.com/onnx/turnkeyml/releases/latest/download/Lemonade_Server_Installer.exe"
    $installerPath = "$env:TEMP\Lemonade_Server_Installer.exe"

    Write-Host "Checking if Lemonade Server Installer is already present..."
    if (Test-Path $installerPath) {
        Write-Host "Lemonade Server Installer found at $installerPath"
    } else {
        Write-Host "Downloading Lemonade Server Installer from $installerUrl..."
        Write-Host "COMMAND: Invoke-WebRequest -Uri '$installerUrl' -OutFile '$installerPath' -ErrorAction Stop"
        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -ErrorAction Stop
            Write-Host "Lemonade Server Installer downloaded successfully to $installerPath"
        } catch {
            Write-Error "Failed to download Lemonade Server Installer: $($_.Exception.Message)"
            return
        }
    }

    Write-Host "Executing Lemonade Server Installer..."
    Write-Host "Please complete the installation manually using the GUI."
    Write-Host "COMMAND: Start-Process -FilePath '$installerPath'"
    try {
        Start-Process -FilePath $installerPath
        Write-Host "Lemonade Server Installer launched. Please complete the installation in the GUI."
    } catch {
        Write-Error "Failed to execute Lemonade Server Installer: $($_.Exception.Message)"
    }
}

function Ensure-LemonadeServer {
    [CmdletBinding()]
    param(
        [int]$Port = 8000,
        [int]$MaxTries = 10,
        [int]$SleepSeconds = 2
    )
    $ServerUrl = "http://localhost:$Port/api/v0/chat/completions"
    $spinner = @('|', '/', '-', '\')
    $spinIndex = 0
    $isInstalled = $false
    $isRunning = $false
    $status = $null

    # Spinner while checking lemonade-server status (using Start-Job)
    Write-Host ""  # Blank line before spinner
    $spinnerMessage = "Getting LLM Aid..."
    $statusJob = Start-Job -ScriptBlock {
        try {
            & lemonade-server status 2>&1
        } catch {
            $null
        }
    }
    while ($statusJob.State -eq 'Running') {
        $spinChar = $spinner[$spinIndex % $spinner.Length]
        [Console]::Write("`r $spinChar $spinnerMessage   ")
        Start-Sleep -Milliseconds 80
        $spinIndex++
    }
    [Console]::Write("`r" + (' ' * 60) + "`r")
    $status = Receive-Job $statusJob
    Remove-Job $statusJob
    if ($status -match "Server is running on port $Port") {
        $isInstalled = $true
        $isRunning = $true
    } elseif ($status -match "Server is not running") {
        $isInstalled = $true
        $isRunning = $false
    }
    if (-not $isInstalled) {
        Write-Error "Lemonade Server is not installed. To use this cmdlet, please run Install-Lemonade to set up Lemonade Server first."
        return $false
    }
    if (-not $isRunning) {
        try {
            $proc = Start-Process -FilePath "lemonade-server" -ArgumentList "serve --port $Port" -WindowStyle Hidden -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 2
            if ($proc.HasExited) {
                Write-Error "Lemonade Server failed to start. The port $Port may already be in use. Try closing other applications using this port or specify a different port."
                return $false
            }
        } catch {
            Write-Error "Failed to start Lemonade Server: $($_.Exception.Message)"
            return $false
        }
    }
    # Spinner animation while waiting for server health
    $spinIndex = 0
    $healthUrl = "http://localhost:$Port/api/v0/health"
    $ready = $false
    $totalTries = $MaxTries
    Write-Host ""  # Blank line before spinner
    while (-not $ready -and $totalTries -gt 0) {
        $spinChar = $spinner[$spinIndex % $spinner.Length]
        [Console]::Write("`r $spinChar Getting LLM Aid...   ")
        try {
            $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {}
        Start-Sleep -Milliseconds 80
        $spinIndex++
        $totalTries--
    }
    [Console]::Write("`r" + (' ' * 60) + "`r")
    if ($ready) {
        return $true
    } else {
        Write-Error "Lemonade Server did not become ready in time."
        return $false
    }
}

function Invoke-AidCore {
    [CmdletBinding()]
    param(
        [string]$Model,
        [int]$Port = 8000,
        [int]$ScrollbackLines = 50
    )
    # Prevent running unless in a PEEL shell
    if (-not ($env:PEEL_SHELL -or $global:PEEL_SHELL)) {
        Write-Error "This command can only be run in a PEEL shell. Please launch the PEEL shell from Windows Terminal."
        return
    }
    $ServerUrl = "http://localhost:$Port/api/v0/chat/completions"
    if (-not (Ensure-LemonadeServer -Port $Port)) {
        Write-Error "Lemonade Server is not available. Exiting."
        return
    }

    $transcriptPath = $global:PEELTranscriptPath
    if ((Test-Path $transcriptPath)) {
        $scrollbackRaw = Get-Content $transcriptPath -Raw
        $scrollback = $scrollbackRaw
        # Optionally trim to last N lines/characters if needed
        $maxChars = 4000
        if ($scrollback.Length -gt $maxChars) {
            $scrollback = $scrollback.Substring($scrollback.Length - $maxChars)
        }
        $scrollback = [string]$scrollback
    } else {
        $scrollback = (Get-History -Count $ScrollbackLines).CommandLine | Out-String
        $scrollback = [string]$scrollback
    }
    $body = @{
        model = $Model
        messages = @(
            @{ role = "system"; content = @"
<assistant>
You are a command-line assistant invoked via Get-Aid (or Get-MoreAid, Get-MaximumAid) whose job is to explain the output of the most recently executed command in the terminal.
Your goal is to help users understand (and potentially fix) things like stack traces, error messages, logs, or any other confusing output from the terminal.
</assistant>

<instructions>

- Receive the last command prior to your invokation and its output (from the transcript scrollback) as context.
- Do not discuss the fact that the transcript is a transcript, focus on the last command.
- Explain the output of the last command.
- Use a clear, concise, and informative tone.
- If the output is an error or warning, e.g. a stack trace or incorrect command, identify the root cause and suggest a fix.
- Otherwise, if the output is something else, e.g. logs or a web response, summarize the key points.
- Don't instruct the user to interact with you futher, as the user doesn't have that ability.

</instructions>
"@ },
            @{ role = "user"; content = $scrollback }
        )
        stream = $true
    } | ConvertTo-Json
    try {
        Add-Type -AssemblyName System.Net.Http
        $handler = New-Object System.Net.Http.HttpClientHandler
        $client = New-Object System.Net.Http.HttpClient($handler)
        $uri = $ServerUrl
        $request = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, "application/json")
        $httpRequest = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $uri)
        $httpRequest.Content = $request
        $response = $client.SendAsync($httpRequest, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $stream = $response.Content.ReadAsStreamAsync().Result
        $reader = New-Object System.IO.StreamReader($stream)
        $firstResponse = $false
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine().Trim()
            if ($line -eq "" -or $line -eq "data: [DONE]" -or $line -eq "[DONE]") { continue }
            if ($line.StartsWith("data: ")) { $line = $line.Substring(6) }
            try {
                $data = $line | ConvertFrom-Json -ErrorAction Stop
                if ($data.choices -and $data.choices[0].delta.content) {
                    if (-not $firstResponse) {
                        [Console]::Write("`r" + (' ' * 60) + "`r")
                        Write-Host "Lemonade Server Response:" -ForegroundColor DarkCyan
                        Write-Host "---------------------------" -ForegroundColor DarkCyan
                        $firstResponse = $true
                    }
                    Write-Host $data.choices[0].delta.content -NoNewline -ForegroundColor Green
                }
            } catch {
                # Ignore lines that aren't valid JSON
                continue
            }
        }
        if (-not $firstResponse) {
            [Console]::Write("`r" + (' ' * 60) + "`r")
        }
        Write-Host ""
    } catch {
        Write-Error "Failed to connect to Lemonade Server: $($_.Exception.Message)"
    }
}

function Get-Aid {
    <#
        .SYNOPSIS
        Explains the output of your most recent terminal command using an LLM.

        .DESCRIPTION
        Captures the last 50 lines of the terminal's scrollback history, sends it to Lemonade Server via the streaming chat completions API, and displays the LLM's response in a streaming fashion within the terminal. Uses the model Llama-3.2-3B-Instruct-Hybrid.
    #>
    [CmdletBinding()]
    param()
    Invoke-AidCore -Model "Llama-3.2-3B-Instruct-Hybrid"
}

function Get-MoreAid {
    <#
        .SYNOPSIS
        Explains the output of your most recent terminal command using an LLM.

        .DESCRIPTION
        Captures the last 50 lines of the terminal's scrollback history, sends it to Lemonade Server via the streaming chat completions API, and displays the LLM's response in a streaming fashion within the terminal. Uses the model Qwen-1.5-7B-Chat-Hybrid.
    #>
    [CmdletBinding()]
    param()
    Invoke-AidCore -Model "Qwen-1.5-7B-Chat-Hybrid"
}

function Get-MaximumAid {
    <#
        .SYNOPSIS
        Explains the output of your most recent terminal command using an LLM.
        .DESCRIPTION
        Captures the last 50 lines of the terminal's scrollback history, sends it to Lemonade Server via the streaming chat completions API, and displays the LLM's response in a streaming fashion within the terminal. Uses the largest available model: DeepSeek-R1-Distill-Qwen-7B-Hybrid.
    #>
    [CmdletBinding()]
    param()
    Invoke-AidCore -Model "DeepSeek-R1-Distill-Qwen-7B-Hybrid"
}

Export-ModuleMember -Function Install-Lemonade, Get-Aid, Get-MoreAid, Get-MaximumAid


