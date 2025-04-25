function Install-PEELModule {
    param(
        [string]$moduleRoot
    )
    try {
        $destinationPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath "WindowsPowerShell\Modules\peel"
        # Always copy to allow updates/fixes
        if (!(Test-Path -Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        }
        # Copy only peel.psm1 to the module root
        $sourceModule = Join-Path -Path $moduleRoot -ChildPath "peel.psm1"
        if (Test-Path $sourceModule) {
            Copy-Item -Path $sourceModule -Destination $destinationPath -Force
        } else {
            Write-Error "Could not find peel.psm1 in $moduleRoot"
            return $false
        }
        return $true
    }
    catch {
        Write-Error "Error copying PEEL module files: $($_.Exception.Message)"
        return $false
    }
}

# Main script
$ErrorActionPreference = "Stop"
$cmdlets = @()
try {
    $VerbosePreference = "Continue"

    # Get the path of the current script
    $scriptPath = $MyInvocation.MyCommand.Definition
    # Get the directory where the script is located
    $moduleRoot = Split-Path $scriptPath

    # Get the path to favicon.ico in the same folder as the script
    $faviconPath = Join-Path $moduleRoot "favicon.ico"

    # Define the destination path for the module in the current user profile, handle errors with try-catch
    try {
        $destinationPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath "PowerShell\Modules\peel"
        # Create the destination directory if it does not exist
        if (!(Test-Path -Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        }
    }
    catch {
        Write-Error "Error creating PowerShell modules directory: $($_.Exception.Message)"
        return
    }
    $installResult = Install-PEELModule -moduleRoot $moduleRoot

    $importSuccess = $true
    $wtProfileSuccess = $true
    try {
        $wtSettingsPath = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        if (Test-Path $wtSettingsPath) {
            $settings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
            $pwshPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $peelCommand = "$pwshPath -NoExit -Command & { `$env:PEEL_SHELL='1'; Import-Module peel }"
            $faviconPath = Join-Path $moduleRoot "favicon.ico"
            # Remove any existing PEEL profile(s)
            if ($settings.profiles.list -is [System.Collections.IEnumerable]) {
                $settings.profiles.list = @($settings.profiles.list | Where-Object { $_.name -ne "PEEL" })
            }
            $peelProfileObj = [PSCustomObject]@{
                name = "PEEL"
                commandline = $peelCommand
                icon = $faviconPath
                startingDirectory = "~"
                hidden = $false
                guid = "{" + ([guid]::NewGuid().ToString()) + "}"
            }
            # Ensure profiles.list is an array
            if ($settings.profiles.list -isnot [System.Collections.IList]) {
                $settings.profiles.list = @($settings.profiles.list)
            }
            $settings.profiles.list += $peelProfileObj
            # Validate JSON before writing
            $json = $settings | ConvertTo-Json -Depth 100
            try {
                $null = $json | ConvertFrom-Json
                $json | Set-Content $wtSettingsPath -Encoding UTF8
            } catch {
                Write-Error "Refusing to write invalid settings.json for Windows Terminal. Aborting installation."
                $wtProfileSuccess = $false
            }
        }
    } catch {
        Write-Error "Could not register PEEL shell in Windows Terminal: $($_.Exception.Message)"
        $wtProfileSuccess = $false
    }

    if ($importSuccess -and $installResult -eq $true -and $wtProfileSuccess) {
        Write-Host "==============================="
        Write-Host " PEEL Module Installation"
        Write-Host "==============================="
        Write-Host "Installed cmdlets:"
        foreach ($cmdlet in $cmdlets) {
            Write-Host "  - $cmdlet"
        }
        Write-Host ""
        Write-Host "To use the Get-Aid cmdlets, open a PEEL shell from Windows Terminal."
        Write-Host ""
        Write-Host "If you don't have Lemonade Server installed, run: Install-Lemonade"
        Write-Host "==============================="
        exit 0
    } else {
        Write-Error "An error occurred while installing or importing the PEEL Module, or updating Windows Terminal profile."
        exit 1
    }
} catch {
    Write-Error $($_.Exception.Message)
    exit 1
}

# Note: The PEEL shell sets the PEEL_SHELL environment variable. peel.psm1 should check for this variable to enable transcript logic only in PEEL shells.

