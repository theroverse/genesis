# ================================================================
# POWERSHELL PROFILE
# ================================================================

# ==========================================
# ALIAS MANAGEMENT
# ==========================================

@('h', 'k', 'g') | ForEach-Object {
    if (Test-Path Alias:$_) {
        Remove-Item Alias:$_ -Force
    }
}

Set-Alias -Name h -Value help-profile -Force
Set-Alias -Name g -Value goto -Force


# ==========================================
# NAVIGATION
# ==========================================

function goto {
    param (
        [Parameter(Mandatory=$false)]
        [string]$location
    )

    $project_path = $HOME

    $locationParts = $location -split '/'

    $locations = @{
        "all"  = "$project_path"
        "avnt" = "$project_path/avnt"
    }

    $basePath = $locations[$locationParts[0]]

    if ($basePath) {
        if ($locationParts.Length -gt 1) {
            $fullPath = Join-Path $basePath (
                $locationParts[1..($locationParts.Length-1)] -join '\'
            )
        }
        else {
            $fullPath = $basePath
        }
    }
    else {
        $fullPath = Join-Path $project_path $location
    }

    if (Test-Path $fullPath) {
        Set-Location -Path $fullPath
        Write-Host "Changed directory to: $fullPath" -ForegroundColor Green
    }
    else {
        Write-Warning "Path '$fullPath' does not exist"

        Write-Host "`nAvailable base locations:" -ForegroundColor Cyan

        $locations.GetEnumerator() | ForEach-Object {
            Write-Host "$($_.Key) => $($_.Value)" -ForegroundColor Yellow
        }
    }
}


# ==========================================
# TOOL DETECTION
# ==========================================

$script:HasKubectl = [bool](
    Get-Command kubectl -ErrorAction SilentlyContinue
)

if ($script:HasKubectl) {

    $kubeConfigPaths = @(
        ".kube/prod-k8s-clcreative-kubeconfig.yaml",
        ".kube/civo-k8s_test_1-kubeconfig",
        ".kube/k8s_test_1.yml"
    )

    $ENV:KUBECONFIG = $kubeConfigPaths -join ";"

    Set-Alias -Name k -Value kubectl -Force

    function kn {
        param (
            [Parameter(Mandatory=$false)]
            [string]$namespace
        )

        try {
            if (
                [string]::IsNullOrEmpty($namespace) -or
                $namespace -in @("default", "d")
            ) {
                kubectl config set-context --current --namespace=default
            }
            else {
                kubectl config set-context --current --namespace=$namespace
            }
        }
        catch {
            Write-Error "Failed to set namespace: $_"
        }
    }
}


# ==========================================
# IDE DETECTION
# ==========================================

$androidStudioPath =
    Join-Path $env:LOCALAPPDATA "Programs\Android Studio\bin\studio64.exe"

$script:HasAndroidStudio = Test-Path $androidStudioPath

if ($script:HasAndroidStudio) {
    Set-Alias as $androidStudioPath
}


$pycharmPath =
    Join-Path $env:LOCALAPPDATA "Programs\PyCharm\bin\pycharm64.exe"

$script:HasPyCharm = Test-Path $pycharmPath

if ($script:HasPyCharm) {
    Set-Alias pc $pycharmPath
}


$webstormBase = "C:\Program Files\JetBrains"
$script:WebStormExe = $null

if (Test-Path $webstormBase) {

    $webstormDir =
        Get-ChildItem `
            -Path $webstormBase `
            -Directory `
            -Filter "WebStorm*" `
            -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($webstormDir) {

        $candidate =
            Join-Path $webstormDir.FullName "bin\webstorm64.exe"

        if (Test-Path $candidate) {
            $script:WebStormExe = $candidate
        }
    }
}

$script:HasWebStorm = [bool]$script:WebStormExe

if ($script:HasWebStorm) {
    Set-Alias ws $script:WebStormExe
}


# ==========================================
# QUICK INSTALLERS
# ==========================================

function install-kubectl {

    Write-Host "Instalando kubectl..." -ForegroundColor Cyan

    winget install -e --id Kubernetes.kubectl

    Write-Host `
        "Pronto. Rode 'reload' para o profile reconhecer o kubectl." `
        -ForegroundColor Green
}


function install-android-studio {

    Write-Host "Instalando Android Studio..." -ForegroundColor Cyan

    winget install -e --id Google.AndroidStudio

    Write-Host `
        "Pronto. Rode 'reload' para o profile reconhecer o alias 'as'." `
        -ForegroundColor Green
}


function install-pycharm {

    Write-Host "Instalando PyCharm..." -ForegroundColor Cyan

    winget install -e --id JetBrains.PyCharm.Community

    Write-Host `
        "Pronto. Rode 'reload' para o profile reconhecer o alias 'pc'." `
        -ForegroundColor Green
}


function install-webstorm {

    Write-Host "Instalando WebStorm..." -ForegroundColor Cyan

    winget install -e --id JetBrains.WebStorm

    Write-Host `
        "Pronto. Rode 'reload' para o profile reconhecer o alias 'ws'." `
        -ForegroundColor Green
}


function install-missing {

    if (-not $script:HasKubectl) {
        install-kubectl
    }

    if (-not $script:HasAndroidStudio) {
        install-android-studio
    }

    if (-not $script:HasPyCharm) {
        install-pycharm
    }

    if (-not $script:HasWebStorm) {
        install-webstorm
    }

    if (
        $script:HasKubectl -and
        $script:HasAndroidStudio -and
        $script:HasPyCharm -and
        $script:HasWebStorm
    ) {
        Write-Host "Nada faltando para instalar." -ForegroundColor Green
    }
}


# ==========================================
# STARSHIP
# ==========================================

$ENV:STARSHIP_CONFIG = "$HOME\.starship\starship.toml"
$ENV:STARSHIP_DISTRO = "者 xcad"

if (Get-Command starship -ErrorAction SilentlyContinue) {

    Invoke-Expression (&starship init powershell)

}
else {

    Write-Warning `
        "Starship is not installed. Install it with: winget install Starship.Starship"
}


# ==========================================
# DATREE COMPLETION
# ==========================================

function __datree_debug {

    if ($env:BASH_COMP_DEBUG_FILE) {
        "$args" |
            Out-File `
                -Append `
                -FilePath "$env:BASH_COMP_DEBUG_FILE"
    }
}


filter __datree_escapeStringWithSpecialChars {

    $_ -replace `
        '\s|#|@|\$|;|,''|\{|\}|\(|\)|"|`|\||<|>|&',
        '`$&'
}


Register-ArgumentCompleter -CommandName 'datree' -ScriptBlock {

    param(
        $WordToComplete,
        $CommandAst,
        $CursorPosition
    )

    $Command = $CommandAst.CommandElements
    $Command = "$Command"

    __datree_debug ""
    __datree_debug "========= starting completion logic =========="
    __datree_debug "WordToComplete: $WordToComplete Command: $Command CursorPosition: $CursorPosition"

    if ($Command.Length -gt $CursorPosition) {
        $Command = $Command.Substring(0, $CursorPosition)
    }

    $ShellCompDirectiveError = 1
    $ShellCompDirectiveNoSpace = 2
    $ShellCompDirectiveNoFileComp = 4
    $ShellCompDirectiveFilterFileExt = 8
    $ShellCompDirectiveFilterDirs = 16

    $Program, $Arguments = $Command.Split(" ", 2)

    $RequestComp = "$Program __complete $Arguments"

    if ($WordToComplete -ne "") {
        $WordToComplete = $Arguments.Split(" ")[-1]
    }

    $IsEqualFlag = ($WordToComplete -Like "--*=*")

    if ($IsEqualFlag) {
        $Flag, $WordToComplete = $WordToComplete.Split("=", 2)
    }

    if (
        $WordToComplete -eq "" -And
        (-Not $IsEqualFlag)
    ) {
        $RequestComp = "$RequestComp" + ' `"`"'
    }

    Invoke-Expression `
        -OutVariable out `
        "$RequestComp" `
        2>&1 |
        Out-Null

    [int]$Directive = $Out[-1].TrimStart(':')

    if ($Directive -eq "") {
        $Directive = 0
    }

    $Out = $Out |
        Where-Object {
            $_ -ne $Out[-1]
        }

    if (
        ($Directive -band $ShellCompDirectiveError) -ne 0
    ) {
        return
    }

    $Longest = 0

    $Values = $Out |
        ForEach-Object {

            $Name, $Description = $_.Split("`t", 2)

            if ($Longest -lt $Name.Length) {
                $Longest = $Name.Length
            }

            if (-Not $Description) {
                $Description = " "
            }

            @{
                Name = "$Name"
                Description = "$Description"
            }
        }

    $Space = " "

    if (
        ($Directive -band $ShellCompDirectiveNoSpace) -ne 0
    ) {
        $Space = ""
    }

    if (
        ($Directive -band $ShellCompDirectiveNoFileComp) -ne 0
    ) {

        if ($Values.Length -eq 0) {
            ""
            return
        }
    }

    if (
        (($Directive -band $ShellCompDirectiveFilterFileExt) -ne 0) -or
        (($Directive -band $ShellCompDirectiveFilterDirs) -ne 0)
    ) {
        return
    }

    $Values = $Values |
        Where-Object {

            $_.Name -like "$WordToComplete*"

            if ($IsEqualFlag) {
                $_.Name = $Flag + "=" + $_.Name
            }
        }

    $Mode =
        (
            Get-PSReadLineKeyHandler |
            Where-Object {
                $_.Key -eq "Tab"
            }
        ).Function

    $Values |
        ForEach-Object {

            $comp = $_

            switch ($Mode) {

                "Complete" {

                    if ($Values.Length -eq 1) {

                        [System.Management.Automation.CompletionResult]::new(
                            $($comp.Name |
                                __datree_escapeStringWithSpecialChars) + $Space,
                            "$($comp.Name)",
                            'ParameterValue',
                            "$($comp.Description)"
                        )
                    }
                    else {

                        while ($comp.Name.Length -lt $Longest) {
                            $comp.Name = $comp.Name + " "
                        }

                        if ($comp.Description -eq " ") {
                            $Description = ""
                        }
                        else {
                            $Description =
                                "  ($($comp.Description))"
                        }

                        [System.Management.Automation.CompletionResult]::new(
                            "$($comp.Name)$Description",
                            "$($comp.Name)$Description",
                            'ParameterValue',
                            "$($comp.Description)"
                        )
                    }
                }

                "MenuComplete" {

                    [System.Management.Automation.CompletionResult]::new(
                        $($comp.Name |
                            __datree_escapeStringWithSpecialChars) + $Space,
                        "$($comp.Name)",
                        'ParameterValue',
                        "$($comp.Description)"
                    )
                }

                Default {

                    [System.Management.Automation.CompletionResult]::new(
                        $($comp.Name |
                            __datree_escapeStringWithSpecialChars),
                        "$($comp.Name)",
                        'ParameterValue',
                        "$($comp.Description)"
                    )
                }
            }
        }
}


# ==========================================
# NODE MODULES CLEANER
# ==========================================

function Clear-NodeModules {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory=$false)]
        [switch]$Log,

        [Parameter(Mandatory=$false)]
        [string]$Path = ".",

        [Parameter(Mandatory=$false)]
        [switch]$WhatIf
    )

    $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $totalSize = 0
    $count = 0

    if ($Log) {

        $logFile =
            "node_modules_removal_log_$(
                (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
            ).txt"

        "Node Modules Removal Log - $date" |
            Out-File $logFile
    }

    Write-Host `
        "`nSearching for node_modules in: $((Resolve-Path $Path).Path)" `
        -ForegroundColor Cyan

    Get-ChildItem `
        -Path $Path `
        -Include "node_modules" `
        -Recurse `
        -Directory |
    ForEach-Object {

        $count++

        $folderSize =
            (
                Get-ChildItem $_.FullName -Recurse |
                Measure-Object -Property Length -Sum
            ).Sum / 1MB

        $totalSize += $folderSize

        $message =
            "`nFound node_modules: $($_.FullName)"

        $sizeMessage =
            "Size: $([Math]::Round($folderSize, 2)) MB"

        Write-Host $message -ForegroundColor Yellow
        Write-Host $sizeMessage -ForegroundColor Cyan

        if ($Log) {
            $message | Out-File $logFile -Append
            $sizeMessage | Out-File $logFile -Append
        }

        if (-not $WhatIf) {

            try {

                Remove-Item `
                    $_.FullName `
                    -Recurse `
                    -Force

                $success = "Successfully removed!"

                Write-Host $success -ForegroundColor Green

                if ($Log) {
                    $success | Out-File $logFile -Append
                }
            }
            catch {

                $errorMessage =
                    "Error removing $($_.FullName): $($_.Exception.Message)"

                Write-Host $errorMessage -ForegroundColor Red

                if ($Log) {
                    $errorMessage | Out-File $logFile -Append
                }
            }
        }

        if ($Log) {
            "------------------------" |
                Out-File $logFile -Append
        }
    }

    $summary = "`nSummary:"
    $summary += "`nTotal folders found: $count"
    $summary +=
        "`nTotal size freed: $([Math]::Round($totalSize, 2)) MB"

    Write-Host $summary -ForegroundColor Magenta

    if ($Log) {

        $summary | Out-File $logFile -Append

        Write-Host `
            "`nLog file created at: $((Get-Item $logFile).FullName)" `
            -ForegroundColor Magenta
    }
}

Set-Alias `
    -Name clear-modules `
    -Value Clear-NodeModules


# ==========================================
# UTILS
# ==========================================

function reload {

    . $PROFILE

    Write-Host `
        "Profile recarregado com sucesso!" `
        -ForegroundColor Green
}


function profile {
    code $PROFILE
}


function myip {

    $local =
        (
            Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object {
                $_.InterfaceAlias -like "*Wi-Fi*" -or
                $_.InterfaceAlias -like "*Ethernet*"
            }
        ).IPAddress

    $public =
        Invoke-RestMethod -Uri "https://api.ipify.org"

    Write-Host "Local IP : " -NoNewline
    Write-Host $local -ForegroundColor Cyan

    Write-Host "Public IP: " -NoNewline
    Write-Host $public -ForegroundColor Green
}


function ports {

    Get-NetTCPConnection -State Listen |
        Select-Object `
            LocalAddress,
            LocalPort,
            OwningProcess,
            @{
                Name = "ProcessName"
                Expression = {
                    (Get-Process -Id $_.OwningProcess).Name
                }
            } |
        Format-Table -AutoSize
}


function gl {

    git log `
        --graph `
        --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' `
        --abbrev-commit
}


function make {
    .\make.bat @args
}


# >>> setup_claude global command >>>
# Gerado automaticamente por thero.py --install-command
# Nao edite manualmente entre estes marcadores; rode novamente
# "python thero.py --install-command" para atualizar.
function thero {
    param(
        [Parameter(Position = 0)]
        [string]$Command,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Rest
    )

    $scriptPath = Join-Path $HOME '.myscripts\thero\thero.py'

    $flagMap = @{
        'install'    = @()
        'skills'     = @('--skills-only')
        'merge'      = @('--merge-only')
        'audit'      = @('--audit')
        'audit-only' = @('--audit-only')
        'index'      = @('--index')
        'check'      = @('--check')
        'update'     = @('--update')
        'help'       = @('--help')
    }

    if ([string]::IsNullOrEmpty($Command)) {
        $flags = @()
    }
    elseif ($flagMap.ContainsKey($Command)) {
        $flags = $flagMap[$Command]
    }
    else {
        # Argumento desconhecido: repassa cru para o script
        # (ex.: --skills-only, -h).
        $flags = @($Command) + $Rest
        $Rest = @()
    }

    python $scriptPath @flags @Rest
}
# <<< setup_claude global command <<<
