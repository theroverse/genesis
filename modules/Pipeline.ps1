# Single source of truth for "what steps exist, in what order, with what
# label". Both genesis.ps1 (console) and gui/WizardHost.ps1 (WebView2) call
# Invoke-GenesisPipeline - the only difference between the two is which
# $Global:GenesisLogSink / $Global:GenesisStepSink they install beforehand
# (see modules/Common.ps1). Get-GenesisStepDefinitions lets the GUI
# pre-populate its step list before anything actually runs.

function Get-GenesisStepDefinitions {
    param($Tasks)

    $defs = [ordered]@{
        RestorePoint            = 'Ponto de restauracao'
        ExecutionPolicy         = 'Execution Policy -> Bypass'
        EnableWSL               = 'Habilitar WSL2 / VirtualMachinePlatform'
        WingetApps              = 'Apps via winget'
        GitHubSsh               = 'Chave SSH + login no GitHub'
        Projects                = 'Pasta de projetos + clonar repositorios'
        Raycast                 = 'Raycast'
        ClaudeCode              = 'Claude Code'
        WinUtil                 = 'WinUtil (atalho na Area de Trabalho)'
        PowerShellProfile       = 'Profile do PowerShell'
        TheroGlobal             = 'thero (instalacao global)'
        DefaultBrowserAndSearch = 'Chrome como navegador/buscador padrao'
        SearchRedirect          = 'Windows Search abrir no navegador padrao'
        Bluetooth               = 'Bluetooth auto-reconnect'
        HomeAssistant           = 'Home Assistant'
        WingetUpgradeTask       = 'Tarefa agendada: winget upgrade --all'
        AutoBackup              = 'Backup automatico de pastas'
        Autologin               = 'Autologin'
    }

    $list = @()
    foreach ($key in $defs.Keys) {
        $enabled = $true
        if ($Tasks.PSObject.Properties.Name -contains $key) {
            $enabled = [bool]$Tasks.$key
        }
        if ($enabled) {
            # minusculo pra bater com o resto do JSON que o app.js consome
            # (id/label/category etc, tudo minusculo) - "Key"/"Label" com
            # maiuscula inicial virava "undefined" em toda linha de "Outras
            # etapas" (JSON e case-sensitive, JS lia s.key/s.label).
            $list += [pscustomobject]@{ key = $key; label = $defs[$key] }
        }
    }
    return $list
}

function Invoke-GenesisPipeline {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Tasks,
        [string[]]$WingetSelectedIds,
        [string[]]$WingetUninstallIds
    )

    $results = [ordered]@{}

    # Pasta de projetos informada na Revisao (config/projects-folder.json) -
    # usada tanto pro clone (Set-ProjectsFolder) quanto pra reescrever o
    # `goto`/`g` do profile (Set-UserProfileScript), que por padrao assume
    # tudo debaixo de $HOME. Vazio = mantem o comportamento antigo (default
    # de cada funcao).
    $projectsFolderPath = Join-Path $Root 'config\projects-folder.json'
    $projectsFolder = if (Test-Path $projectsFolderPath) {
        (Get-Content -Raw -Path $projectsFolderPath | ConvertFrom-Json).path
    } else { '' }

    # Arquivo adicional de profile informado na etapa "Profile do
    # PowerShell" (config/profile-custom-path.json) - ver o comentario
    # grande em Get-MergedProfileContent (modules/Setup-PowerShellProfile.ps1).
    $customProfilePathPath = Join-Path $Root 'config\profile-custom-path.json'
    $customProfilePath = if (Test-Path $customProfilePathPath) {
        (Get-Content -Raw -Path $customProfilePathPath | ConvertFrom-Json).path
    } else { '' }

    function Get-Task2 {
        param($n)
        if ($Tasks.PSObject.Properties.Name -contains $n) { return [bool]$Tasks.$n }
        return $false
    }

    if (Get-Task2 'RestorePoint') {
        $results['RestorePoint'] = Invoke-Step -Key 'RestorePoint' -Name 'Ponto de restauracao' -Action {
            New-GenesisRestorePoint
        }
    }
    if (Get-Task2 'ExecutionPolicy') {
        $results['ExecutionPolicy'] = Invoke-Step -Key 'ExecutionPolicy' -Name 'Execution Policy -> Bypass' -Action {
            Set-ExecutionPolicyBypassAll
        }
    }
    if (Get-Task2 'EnableWSL') {
        $results['EnableWSL'] = Invoke-Step -Key 'EnableWSL' -Name 'Habilitar WSL2 / VirtualMachinePlatform' -Action {
            Enable-WSLFeatures
        }
    }
    if (Get-Task2 'WingetApps') {
        $results['WingetApps'] = Invoke-Step -Key 'WingetApps' -Name 'Apps via winget' -Action {
            Install-WingetApps -ConfigPath (Join-Path $Root 'config\winget-apps.json') -SelectedIds $WingetSelectedIds -UninstallIds $WingetUninstallIds
        }
    }
    if (Get-Task2 'GitHubSsh') {
        $results['GitHubSsh'] = Invoke-Step -Key 'GitHubSsh' -Name 'Chave SSH + login no GitHub' -Action {
            Set-GitHubSsh -Email 'antherovn@gmail.com'
        }
    }
    if (Get-Task2 'Projects') {
        $results['Projects'] = Invoke-Step -Key 'Projects' -Name 'Pasta de projetos + clonar repositorios' -Action {
            if ($projectsFolder) {
                Set-ProjectsFolder -ConfigPath (Join-Path $Root 'config\projects.json') -ProjectsDir $projectsFolder
            }
            else {
                Set-ProjectsFolder -ConfigPath (Join-Path $Root 'config\projects.json')
            }
        }
    }
    if (Get-Task2 'Raycast') {
        $results['Raycast'] = Invoke-Step -Key 'Raycast' -Name 'Raycast' -Action {
            Invoke-RaycastInstaller -ExePath (Join-Path $Root 'raycast-installer.exe')
        }
    }
    if (Get-Task2 'ClaudeCode') {
        $results['ClaudeCode'] = Invoke-Step -Key 'ClaudeCode' -Name 'Claude Code' -Action { Install-ClaudeCode }
    }
    if (Get-Task2 'WinUtil') {
        $results['WinUtil'] = Invoke-Step -Key 'WinUtil' -Name 'WinUtil (atalho na Area de Trabalho)' -Action {
            Install-WinUtilShortcut
        }
    }
    if (Get-Task2 'PowerShellProfile') {
        $results['PowerShellProfile'] = Invoke-Step -Key 'PowerShellProfile' -Name 'Profile do PowerShell' -Action {
            Set-UserProfileScript -SourceProfile (Join-Path $Root 'Microsoft.PowerShell_profile.ps1') -ProjectsPath $projectsFolder -CustomProfilePath $customProfilePath
        }
    }
    if (Get-Task2 'TheroGlobal') {
        $results['TheroGlobal'] = Invoke-Step -Key 'TheroGlobal' -Name 'thero (instalacao global)' -Action {
            Install-TheroGlobal
        }
    }

    if (Get-Task2 'DefaultBrowserAndSearch') {
        $results['DefaultBrowserAndSearch'] = Invoke-Step -Key 'DefaultBrowserAndSearch' -Name 'Chrome como navegador/buscador padrao' -Action {
            Set-DefaultBrowserAndSearch
        }
    }
    if (Get-Task2 'SearchRedirect') {
        $results['SearchRedirect'] = Invoke-Step -Key 'SearchRedirect' -Name 'Windows Search abrir no navegador padrao' -Action {
            Install-SearchRedirect
        }
    }
    if (Get-Task2 'Bluetooth') {
        $results['Bluetooth'] = Invoke-Step -Key 'Bluetooth' -Name 'Bluetooth auto-reconnect' -Action {
            Set-BluetoothAutoReconnect
        }
    }
    if (Get-Task2 'HomeAssistant') {
        $results['HomeAssistant'] = Invoke-Step -Key 'HomeAssistant' -Name 'Home Assistant' -Action {
            Invoke-HomeAssistantSetup -ConfigPath (Join-Path $Root 'config\home-assistant-vm.json')
        }
    }
    if (Get-Task2 'WingetUpgradeTask') {
        $results['WingetUpgradeTask'] = Invoke-Step -Key 'WingetUpgradeTask' -Name 'Tarefa agendada: winget upgrade --all' -Action {
            Register-WingetUpgradeTask
        }
    }
    if (Get-Task2 'AutoBackup') {
        $results['AutoBackup'] = Invoke-Step -Key 'AutoBackup' -Name 'Backup automatico de pastas' -Action {
            Register-BackupTasks -FoldersPath (Join-Path $Root 'config\backup-folders.json')
        }
    }
    if (Get-Task2 'Autologin') {
        $results['Autologin'] = Invoke-Step -Key 'Autologin' -Name 'Autologin (Sysinternals Autologon)' -Action {
            Enable-WindowsAutologin
        }
    }

    return [pscustomobject]@{
        Results           = $results
        RebootRecommended = $script:RebootRecommended
    }
}
