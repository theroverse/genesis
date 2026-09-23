#Requires -Version 5.1
<#
    Native shell for the wizard: a borderless WinForms window hosting a
    WebView2 control pointed at gui/wizard/index.html. The HTML/CSS/JS is
    the whole UI (see gui/wizard/) - this file only bridges it to the real
    automation engine in modules/Pipeline.ps1, the same one genesis.ps1 and
    the old gui/App.ps1 used.

    Message protocol (JSON, one object per message):
      JS -> PS : { type: 'get-config' | 'start-install' | 'open-app'
                        | 'get-launchable' | 'search-apps' | 'browse-folder'
                        | 'browse-file' | 'ensure-projects-folder'
                        | 'list-presets' | 'load-preset' | 'browse-preset-file'
                        | 'save-preset' | 'preview-profile'
                        | 'window-close' | 'window-minimize' | 'window-tray'
                        | 'window-drag',
                   payload: <anything the handler needs> }
      PS -> JS : { type: 'config' | 'step' | 'log' | 'done' | 'launchable'
                        | 'search-results' | 'app-status' | 'installed-apps'
                        | 'browse-result' | 'projects-folder-result'
                        | 'presets-found' | 'preset-loaded' | 'preset-saved'
                        | 'profile-preview',
                   payload: <...> }
#>

param([switch]$SkipElevationCheck)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-AppRoot {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $exeName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
    if ($exeName -match '^(powershell|pwsh)$') {
        return Split-Path -Parent $PSScriptRoot
    }
    return Split-Path -Parent $exePath
}

$ExeDir = Get-AppRoot
$exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$exeName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)

# Elevacao ANTES de qualquer UI: sem admin, relanca elevado e sai. A
# checagem e inline (sem depender de modules/Common.ps1, que so existe
# DEPOIS da extracao do payload).
if (-not $SkipElevationCheck) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if ($exeName -match '^(powershell|pwsh)$') {
            Start-Process -FilePath $exePath -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-SkipElevationCheck'
            )
        }
        else {
            Start-Process -FilePath $exePath -Verb RunAs -ArgumentList @('-SkipElevationCheck')
        }
        exit
    }
}

# --- native drag support + rounded corners (estilo Discord, Windows 11) -----
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeDrag {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public const int WM_NCLBUTTONDOWN = 0xA1;
    public const int HTCAPTION = 0x2;
    // Windows 11: cantos arredondados do proprio OS. No Win10 a chamada so
    // retorna erro e o canto fica reto - sem quebrar nada. Assinatura com
    // IntPtr (nao Forms.Form): Add-Type sem -ReferencedAssemblies nao compila
    // tipos de System.Windows.Forms e o Add-Type inteiro falharia, matando
    // tambem o drag da titlebar.
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2;
    public static void RoundCorners(IntPtr hwnd) {
        try {
            int pref = DWMWCP_ROUND;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, 4);
        }
        catch { }
    }
}
'@

# Genesis.exe de arquivo unico: se o payload embutido existe (ver
# scripts/build-payload.ps1 + gui/GenesisBootstrap.ps1), $Root passa a ser a
# pasta extraida em %LOCALAPPDATA%\Genesis\app\<versao> - com modules/,
# config/, gui/ e python/ dentro dela. Rodando direto da pasta do projeto
# (dev) nao ha payload, entao nada muda: $Root e a propria pasta do exe.
#
# Tudo daqui ate o ShowDialog roda ANTES de qualquer message loop - um erro
# terminante nesse trecho (payload corrompido, DLL do WebView2 faltando,
# etc.) matava o processo sem aviso nenhum, sem MessageBox nem log. O trap
# cobre da linha seguinte ate o fim do script (inclui $Root, dot-source,
# Add-Type do WebView2, criacao do form/webView e o webView.Source la
# embaixo) - "break" faz o processo parar ali em vez de tentar continuar
# com estado pela metade.
trap {
    $crashMsg = "Genesis falhou ao iniciar:`n`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'Genesis\logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        $crashMsg | Out-File (Join-Path $logDir "crash-startup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log") -Encoding utf8
    }
    catch { }
    [System.Windows.Forms.MessageBox]::Show($crashMsg, 'Genesis', 'OK', 'Error')
    exit 1
}

$Root = if ($Global:GenesisPayloadBase64) { Expand-GenesisPayload -ExeDir $ExeDir } else { $ExeDir }
. (Join-Path $Root 'modules\Common.ps1')
. (Join-Path $Root 'modules\Pipeline.ps1')
# So essas duas rodam automaticamente na thread principal (dot-source do
# resto dos modules e so dentro da runspace de instalacao, ver
# Start-InstallRun) - Get-MergedProfileContent/Set-ProfileProjectPath
# precisam estar aqui tambem pro handler 'preview-profile' (roda na
# thread principal, ao vivo, antes de qualquer instalacao comecar).
. (Join-Path $Root 'modules\Setup-PowerShellProfile.ps1')

# ------------------------------------------------------------------ presets --

# Pasta dedicada, fora do Root: sobrevive a reinstalacao do exe e a extracao
# pra uma pasta NOVA a cada versao do payload (Expand-GenesisPayload usa
# %LOCALAPPDATA%\Genesis\app\<hash>, que muda a cada build) - mesmo padrao
# de %LOCALAPPDATA%\Genesis\WebView2 usado logo abaixo.
$script:PresetsDir = Join-Path $env:LOCALAPPDATA 'Genesis\Presets'
$script:PresetExt = '.gnpreset'

function Initialize-PresetsFolder {
    if (-not (Test-Path $script:PresetsDir)) {
        New-Item -ItemType Directory -Path $script:PresetsDir -Force | Out-Null
    }
    $readme = Join-Path $script:PresetsDir 'LEIA-ME.txt'
    if (-not (Test-Path $readme)) {
        @'
Presets do Genesis
===================

Coloque aqui arquivos .gnpreset para o assistente identifica-los sozinho na
tela inicial (se achar mais de um, ele deixa voce escolher qual usar).

Para criar um preset novo: marque os apps/etapas que quiser no assistente
e, ao clicar em "Instalar agora", ele pergunta se voce quer salvar essa
combinacao - o arquivo cai automaticamente aqui.

Tambem da pra abrir um preset de qualquer lugar: arraste o arquivo
.gnpreset para a tela inicial do assistente, cole o conteudo JSON dele
diretamente, ou use o botao "Procurar arquivo".
'@ | Set-Content -Path $readme -Encoding utf8
    }
}

function Get-PresetSummary {
    param([string]$Path)
    try {
        $data = Get-Content -Raw -Path $Path | ConvertFrom-Json
        if (-not $data.genesisPreset) { return $null }
        [pscustomobject]@{
            fileName  = Split-Path -Leaf $Path
            name      = if ($data.name) { $data.name } else { [System.IO.Path]::GetFileNameWithoutExtension($Path) }
            createdAt = $data.createdAt
            appCount  = @($data.selectedApps).Count
        }
    }
    # Arquivo corrompido/nao-JSON na pasta: ignora em vez de derrubar a
    # lista inteira - a pasta e livre pra qualquer coisa cair nela.
    catch { $null }
}

function Get-PresetsList {
    if (-not (Test-Path $script:PresetsDir)) { return @() }
    Get-ChildItem -Path $script:PresetsDir -Filter "*$script:PresetExt" -File |
        ForEach-Object { Get-PresetSummary -Path $_.FullName } |
        Where-Object { $_ }
}

function Get-PresetFileName {
    param([string]$Name)
    $safe = ($Name -replace '[^\p{L}\p{N} _-]', '').Trim()
    if (-not $safe) { $safe = 'preset' }
    $safe = $safe -replace '\s+', '-'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return "$safe-$stamp$script:PresetExt"
}

# [array] nos dois campos: mesmo bug de sempre (ver o comentario grande em
# Get-CurrentConfig) - um preset salvo com EXATAMENTE 1 app ou 1 extra
# desenrola pra escalar no ConvertFrom-Json, e sem o cast aqui o app.js
# receberia uma string em vez de array (`new Set("Git.Git")` vira um Set de
# CADA CARACTERE da string, nao o app inteiro).
function Get-NormalizedPreset {
    param($Data)
    [pscustomobject]@{
        genesisPreset = $true
        name          = $Data.name
        createdAt     = $Data.createdAt
        selectedApps  = [array]$Data.selectedApps
        tasks         = $Data.tasks
        extraApps     = [array]$Data.extraApps
    }
}

Initialize-PresetsFolder

# --- WebView2 assemblies (shipped in gui/webview2/, see README) -----------
$wv2Dir = Join-Path $Root 'gui\webview2'
Add-Type -Path (Join-Path $wv2Dir 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $wv2Dir 'Microsoft.Web.WebView2.WinForms.dll')
$env:PATH = "$wv2Dir;$env:PATH"

# ------------------------------------------------------------------- form --
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Genesis - setup pos-formatacao'
# Icone da janela (e o que a barra de tarefas mostra - o -iconFile do ps2exe
# so marca o ARQUIVO .exe no Explorer). O .ico viaja dentro do payload
# (scripts/build-payload.ps1 inclui gui/Genesis.ico) e cai aqui ja extraido.
try {
    $iconPath = Join-Path $Root 'gui\Genesis.ico'
    if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }
}
catch { }
$form.Size = New-Object System.Drawing.Size(1280, 820)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'None'
$form.BackColor = [System.Drawing.Color]::FromArgb(10, 14, 26)
$form.Add_Shown({ [NativeDrag]::RoundCorners($form.Handle) })

# --- bandeja (tray) ---------------------------------------------------------
# "Minimizar para o tray" (so aparece durante a instalacao, ver app.js) -
# esconde a janela inteira e mostra um icone no tray; qualquer clique nele
# (ou o fim da instalacao, no timer 'Done' mais abaixo) restaura a janela.
$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
# Instancia PROPRIA de Icon, nao reaproveita $form.Icon: os dois
# compartilhando o mesmo objeto Icon e uma causa conhecida do
# Shell_NotifyIcon falhar CALADO (sem excecao .NET nenhuma - o icone so
# nunca aparece, nem escondido) quando o handle GDI+ e compartilhado entre
# a janela e o NotifyIcon.
$script:trayIconIcon = $null
try {
    $iconPathTray = Join-Path $Root 'gui\Genesis.ico'
    if (Test-Path $iconPathTray) { $script:trayIconIcon = New-Object System.Drawing.Icon($iconPathTray) }
}
catch { }
if (-not $script:trayIconIcon) { $script:trayIconIcon = [System.Drawing.SystemIcons]::Application }
$script:trayIcon.Icon = $script:trayIconIcon
$script:trayIcon.Text = 'Genesis - instalando...'
$script:trayIcon.Visible = $false
function Show-GenesisWindow {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
    $script:trayIcon.Visible = $false
}
# Click esquerdo (comportamento padrao) E duplo-clique (habito comum em
# icone de bandeja) restauram a janela; menu do botao direito tambem, pra
# quem prefere clicar com o direito em vez de clicar direto no icone.
$script:trayIcon.Add_Click({ Show-GenesisWindow })
$script:trayIcon.Add_DoubleClick({ Show-GenesisWindow })
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenuOpen = New-Object System.Windows.Forms.ToolStripMenuItem('Abrir Genesis')
$trayMenuOpen.Add_Click({ Show-GenesisWindow })
[void]$trayMenu.Items.Add($trayMenuOpen)
$script:trayIcon.ContextMenuStrip = $trayMenu
$form.Add_FormClosing({ $script:trayIcon.Visible = $false })
$form.Add_FormClosed({ $script:trayIcon.Dispose() })

$webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$webView.Dock = 'Fill'

# Without this, WebView2's lazy default-environment init creates a
# "<exe name>.WebView2" folder RIGHT NEXT TO the exe (cache, cookies,
# etc.) the first time it runs - annoying clutter in the install folder.
# Setting CreationProperties before the control ever navigates redirects
# that data to the user's own AppData instead, same as any other app.
$creationProps = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$creationProps.UserDataFolder = Join-Path $env:LOCALAPPDATA 'Genesis\WebView2'
$webView.CreationProperties = $creationProps

$form.Controls.Add($webView)

$indexPath = Join-Path $Root 'gui\wizard\index.html'
$queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:pythonExe = $null

# ---------------------------------------------------------- config payload --

function Get-CurrentConfig {
    $tasksPath = Join-Path $Root 'config\tasks.json'
    $wingetPath = Join-Path $Root 'config\winget-apps.json'
    $haPath = Join-Path $Root 'config\home-assistant-vm.json'
    $projectsPath = Join-Path $Root 'config\projects.json'
    $projectsFolderPath = Join-Path $Root 'config\projects-folder.json'
    $customProfilePathPath = Join-Path $Root 'config\profile-custom-path.json'
    $backupPath = Join-Path $Root 'config\backup-folders.json'
    $presetupPath = Join-Path $Root 'presetup.json'
    $profileSourcePath = Join-Path $Root 'Microsoft.PowerShell_profile.ps1'

    $tasks = Get-Content -Raw -Path $tasksPath | ConvertFrom-Json
    $wingetApps = Get-Content -Raw -Path $wingetPath | ConvertFrom-Json
    $ha = Get-Content -Raw -Path $haPath | ConvertFrom-Json
    $projects = Get-Content -Raw -Path $projectsPath | ConvertFrom-Json
    $projectsFolder = if (Test-Path $projectsFolderPath) { (Get-Content -Raw -Path $projectsFolderPath | ConvertFrom-Json).path } else { '' }
    $customProfilePath = if (Test-Path $customProfilePathPath) { (Get-Content -Raw -Path $customProfilePathPath | ConvertFrom-Json).path } else { '' }
    $backupFolders = if (Test-Path $backupPath) { Get-Content -Raw -Path $backupPath | ConvertFrom-Json } else { @() }
    $stepDefs = Get-GenesisStepDefinitions -Tasks $tasks
    # Fonte crua do profile PADRAO, em base64: so serve de preview inicial
    # rapida (evita tela em branco) antes da primeira resposta de
    # 'preview-profile' chegar - essa sim monta o preview de verdade
    # (padrao + o que ja existe na maquina + o arquivo adicional que o
    # usuario apontar), via Get-MergedProfileContent
    # (modules/Setup-PowerShellProfile.ps1). Nao da pra fazer esse merge
    # aqui: a etapa "Profile do PowerShell" precisa saber $PROFILE local e
    # ler um arquivo arbitrario que so o JS sabe o caminho depois que o
    # usuario escolhe - por isso e sob demanda, nao no config inicial.
    #
    # PRECISA ser base64, nao a string crua: ConvertTo-Json do Windows
    # PowerShell 5.1 serializa esse profile especifico (~70KB, cheio de
    # ASCII art/caracteres especiais da lockscreen) como
    # {"profileSource":{"value":"...","Count":N}} em vez de uma string JSON
    # normal, e o tamanho desse wrapper cresce EXPONENCIALMENTE a cada nivel
    # de -Depth (confirmado: ~78KB no depth 3, ~2,3MB no depth 6,
    # OutOfMemoryException no -Depth 8 que o Send-ToJs usa) - a wizard
    # inteira ficava em branco pra sempre porque o 'config' nunca chegava
    # no JS. Uma string base64 (so A-Z/a-z/0-9/+//=) nunca aciona esse bug;
    # app.js decodifica com atob()+TextDecoder antes de usar.
    $profileSourceB64 = if (Test-Path $profileSourcePath) {
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Raw -Path $profileSourcePath)))
    } else { '' }

    # presetup.json is optional and gitignored - it exists only on machines
    # its owner set up, carrying personal values (their own VDI path, their
    # own repos) that a generic checkout of this project should NOT ship
    # with. When present, it pre-fills those fields; when absent, they
    # stay whatever's in the tracked config (empty, by default).
    if (Test-Path $presetupPath) {
        $presetup = Get-Content -Raw -Path $presetupPath | ConvertFrom-Json
        if ($presetup.homeAssistantVdiPath) { $ha.VdiPath = $presetup.homeAssistantVdiPath }
        if ($presetup.projects) { $projects = $presetup.projects }
        if ($presetup.projectsFolder) { $projectsFolder = $presetup.projectsFolder }
    }

    # [array] casts below are load-bearing, not decoration: Windows
    # PowerShell 5.1's ConvertTo-Json serializes a bare [object[]] that
    # was assigned as a NESTED property (i.e. one level down in another
    # object, exactly what happens when this whole thing gets wrapped by
    # Send-ToJs) as {"value":[...],"Count":N} instead of a plain JSON
    # array - an [array] cast forces the correct array output. Verified
    # empirically; drop this cast and the wizard silently breaks on
    # config load (app.js's .map() calls throw because the field is an
    # object, not an array).
    [pscustomobject]@{
        tasks         = $tasks
        wingetApps    = [array]$wingetApps
        homeAssistant = [pscustomobject]@{
            mode       = if ($ha.Mode) { $ha.Mode } else { 'vm' }
            vdiPath    = $ha.VdiPath
            backupPath = $ha.BackupPath
        }
        projects      = [array]$projects
        projectsFolder = $projectsFolder
        customProfilePath = $customProfilePath
        backupFolders = [array]$backupFolders
        stepDefs      = [array]$stepDefs
        profileSourceB64 = $profileSourceB64
        presetsDir    = $script:PresetsDir
    }
}

function Save-WizardChoices {
    param($Payload)

    $tasksPath = Join-Path $Root 'config\tasks.json'
    $wingetPath = Join-Path $Root 'config\winget-apps.json'
    $haPath = Join-Path $Root 'config\home-assistant-vm.json'
    $projectsPath = Join-Path $Root 'config\projects.json'
    $backupPath = Join-Path $Root 'config\backup-folders.json'

    $Payload.tasks | ConvertTo-Json | Set-Content -Path $tasksPath -Encoding utf8

    # NAO envolve o pipe inteiro em @(...) (era "$catalog = @(Get-Content ...
    # | ConvertFrom-Json)") - "@( A | B )" com B devolvendo um array NAO
    # desenrola: o array inteiro vira o UNICO item de um novo array externo
    # ($catalog.Count = 1, $catalog[0] = os 59 apps de verdade). Dai
    # "foreach ($app in $catalog)" rodava UMA vez so, com $app sendo o
    # array inteiro - "$app.id" auto-enumerava pra um array de 59 ids (o
    # -contains nunca batia, $isDefault sempre $false) e "$app | Add-Member"
    # desenrolava de volta nos 59 objetos reais, entao SEM -Force o primeiro
    # (que ja tem `default`) estourava "ja existe um membro com esse nome" -
    # e mesmo COM -Force so mascarava o sintoma: todo app saia com
    # default=false, silenciosamente. Ler primeiro, DEPOIS castar com
    # [array] no proprio caminho documentado no resto do arquivo evita o
    # bug - a atribuicao simples ($catalog = Get-Content ... | ConvertFrom-
    # Json) ja desenrola certo.
    $catalog = Get-Content -Raw -Path $wingetPath | ConvertFrom-Json
    $catalog = [array]$catalog
    $selected = @($Payload.selectedAppIds)
    foreach ($app in $catalog) {
        # hashtable (ConvertFrom-Json -AsHashtable) ou PSCustomObject: os dois
        # precisam de escrita defensiva. -Force no Add-Member continua aqui
        # como rede de seguranca (idempotente mesmo se `default` ja existir),
        # nao pra mascarar o bug acima - esse ja foi corrigido na leitura.
        $isDefault = [bool]($selected -contains $(if ($app -is [hashtable]) { $app['id'] } else { $app.id }))
        if ($app -is [hashtable]) { $app['default'] = $isDefault }
        else { $app | Add-Member -NotePropertyName 'default' -NotePropertyValue $isDefault -Force }
    }

    # Apps added on the "Adicionar mais" search screen aren't in the
    # static catalog yet - fold them in (once) so Install-WingetApps can
    # install them like any other entry, and so they're remembered on
    # future runs instead of vanishing after this one.
    foreach ($extra in $Payload.extraApps) {
        if ($catalog.id -notcontains $extra.id) {
            $catalog += [pscustomobject]@{
                id = $extra.id; label = $extra.label; category = 'Extra'
                default = $true; version = $extra.version; updated = $extra.updated
                homepage = $extra.homepage; source = $extra.source
            }
        }
    }
    $catalog | ConvertTo-Json -Depth 5 | Set-Content -Path $wingetPath -Encoding utf8

    $ha = Get-Content -Raw -Path $haPath | ConvertFrom-Json
    # $ha pode ser hashtable ou PSCustomObject dependendo de quem leu o JSON:
    # escreve de forma defensiva pra nunca quebrar com "propriedade nao
    # encontrada" no meio do start-install.
    $haMode = $Payload.homeAssistant.mode
    $haVdi = $Payload.homeAssistant.vdiPath
    $haBackup = $Payload.homeAssistant.backupPath
    if ($ha -is [hashtable]) {
        $ha['Mode'] = $haMode; $ha['VdiPath'] = $haVdi; $ha['BackupPath'] = $haBackup
    }
    else {
        foreach ($pair in @(@('Mode', $haMode), @('VdiPath', $haVdi), @('BackupPath', $haBackup))) {
            $ha | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
    }
    $ha | ConvertTo-Json | Set-Content -Path $haPath -Encoding utf8

    # [array] casts: same single-element unwrap risk as noted on
    # Get-CurrentConfig, this time on the way back in from JS - a JSON
    # array with exactly one item deserializes to a bare scalar in
    # Windows PowerShell 5.1's ConvertFrom-Json, and re-serializing that
    # scalar would corrupt these files' array schema.
    [array]$Payload.projects | ConvertTo-Json -Depth 5 | Set-Content -Path $projectsPath -Encoding utf8
    [array]$Payload.backupFolders | ConvertTo-Json -Depth 3 | Set-Content -Path $backupPath -Encoding utf8

    $projectsFolderPath = Join-Path $Root 'config\projects-folder.json'
    @{ path = $Payload.projectsFolder } | ConvertTo-Json | Set-Content -Path $projectsFolderPath -Encoding utf8

    $customProfilePathPath = Join-Path $Root 'config\profile-custom-path.json'
    @{ path = $Payload.customProfilePath } | ConvertTo-Json | Set-Content -Path $customProfilePathPath -Encoding utf8
}

# --------------------------------------------------------- launchable apps --

function Find-StartApp {
    param([string]$NameQuery)
    try { Get-StartApps | Where-Object { $_.Name -like "*$NameQuery*" } | Select-Object -First 1 }
    catch { $null }
}

function Get-LaunchableApps {
    param($Results, $Config)

    $items = @()
    $wingetSelected = $Config.wingetApps | Where-Object { $_.default }
    foreach ($app in $wingetSelected) {
        $found = Find-StartApp -NameQuery $app.label
        if ($found) {
            $items += [pscustomobject]@{ label = $found.Name; action = @{ kind = 'app'; appId = $found.AppID } }
        }
    }
    if ($Results.ClaudeCode) {
        $items += [pscustomobject]@{ label = 'Claude Code (terminal)'; action = @{ kind = 'claude' } }
    }
    if ($Results.HomeAssistant) {
        $items += [pscustomobject]@{ label = 'Home Assistant (navegador)'; action = @{ kind = 'browser'; url = 'http://localhost:8123' } }
    }
    return $items
}

# -------------------------------------------------------------- bridge in --

function Send-ToJs {
    param([string]$Type, $Payload)
    # [array] cast: see the long comment on Get-CurrentConfig - any array
    # handed to -Payload is about to become a NESTED property of the
    # wrapper hashtable below, which is exactly where Windows PowerShell
    # 5.1's ConvertTo-Json mangles a bare array into {"value":...,"Count":N}.
    # Doing the cast here once protects every caller instead of relying on
    # each call site to remember it.
    #
    # -isnot IDictionary e essencial: Hashtable (o -Payload @{...} que quase
    # todo call site usa) TAMBEM implementa ICollection, entao sem essa
    # exclusao um payload como @{ ok = $true } virava [{"ok":true}] (array
    # de 1 item) em vez de {"ok":true} - e no JS `msg.payload.ok` some
    # (undefined, sempre falso) porque payload virou array, nao objeto.
    # Confirmado: isso quebrava 'projects-folder-result' (o campo da pasta
    # de projetos ficava preso em loop de refoco) e, em tese, qualquer outro
    # Send-ToJs com Hashtable de 1 propriedade so - o bug so nao aparecia
    # antes porque o preview mock (dev.ps1) nunca passa por essa funcao.
    if (($Payload -is [array] -or $Payload -is [System.Collections.ICollection]) -and $Payload -isnot [System.Collections.IDictionary]) {
        $Payload = [array]$Payload
    }
    $msg = @{ type = $Type; payload = $Payload } | ConvertTo-Json -Depth 8 -Compress
    $webView.CoreWebView2.PostWebMessageAsJson($msg)
}

$script:lastResults = @{}
$script:lastConfig = $null

function Handle-Message {
    param($Msg)

    switch ($Msg.type) {
        'get-config' {
            $script:lastConfig = Get-CurrentConfig
            Send-ToJs -Type 'config' -Payload $script:lastConfig
            Start-InstalledAppsCheck
        }
        'start-install' {
            # JS ja pulou pra tela de progresso ("Instalando...") assim que
            # mandou essa mensagem, antes de saber se isso aqui vai dar
            # certo (ver startInstall em app.js). Sem esse try/catch, um erro
            # aqui (Save-WizardChoices ou Start-InstallRun) deixava o
            # usuario travado nessa tela pra sempre - "Voltar" fica
            # desabilitado no step 'progress' e nenhum evento de instalacao
            # nunca chega pra destravar. 'install-start-failed' manda o JS
            # de volta pra Revisao.
            try {
                Save-WizardChoices -Payload $Msg.payload
                Start-InstallRun -Payload $Msg.payload
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Nao foi possivel iniciar a instalacao:`n`n$($_.Exception.Message)",
                    'Genesis', 'OK', 'Error')
                Send-ToJs -Type 'install-start-failed' -Payload @{}
            }
        }
        'open-app' {
            $action = $Msg.payload
            switch ($action.kind) {
                'app' { Start-Process 'explorer.exe' "shell:AppsFolder\$($action.appId)" }
                'claude' { Start-Process 'powershell.exe' -ArgumentList '-NoExit', '-Command', 'claude' }
                'browser' { Start-Process $action.url }
            }
        }
        'get-launchable' {
            $config = Get-CurrentConfig
            Send-ToJs -Type 'launchable' -Payload (Get-LaunchableApps -Results $script:lastResults -Config $config)
        }
        'search-apps' { Start-AppSearch -Query $Msg.payload.query }
        'preview-profile' {
            # Sob demanda (nao no config inicial): precisa saber o $PROFILE
            # de verdade dessa maquina e ler um arquivo arbitrario que o
            # usuario acabou de apontar na etapa "Profile do PowerShell" -
            # ver o comentario grande em Get-CurrentConfig.
            try {
                $merged = Get-MergedProfileContent -SourceProfile (Join-Path $Root 'Microsoft.PowerShell_profile.ps1') `
                    -ExistingProfilePath $PROFILE.CurrentUserAllHosts -CustomProfilePath $Msg.payload.customPath
                $merged = Set-ProfileProjectPath -Content $merged -ProjectsPath $Msg.payload.projectsFolder
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($merged)
                Send-ToJs -Type 'profile-preview' -Payload @{ ok = $true; contentB64 = [Convert]::ToBase64String($bytes) }
            }
            catch {
                Send-ToJs -Type 'profile-preview' -Payload @{ ok = $false; error = $_.Exception.Message }
            }
        }
        'ensure-projects-folder' {
            # Roda ao clicar "Instalar agora" na Revisao: a pasta pode nao
            # existir ainda (o campo aceita digitar um caminho novo) - tenta
            # criar aqui. Falhou -> MessageBox com o erro real e a instalacao
            # NAO avanca (o JS so chama startInstall no ok:true); vazio ->
            # ok direto, nada pra clonar/criar.
            $path = $Msg.payload.path
            $ok = $true
            if ($path -and -not (Test-Path $path)) {
                try { New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null }
                catch {
                    $ok = $false
                    [System.Windows.Forms.MessageBox]::Show(
                        "Nao foi possivel criar a pasta de projetos:`n$path`n`n$($_.Exception.Message)",
                        'Genesis', 'OK', 'Error')
                }
            }
            Send-ToJs -Type 'projects-folder-result' -Payload @{ ok = $ok }
        }
        'browse-folder' {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                Send-ToJs -Type 'browse-result' -Payload @{
                    field = $Msg.payload.field; index = $Msg.payload.index; path = $dialog.SelectedPath
                }
            }
        }
        'browse-file' {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            if ($Msg.payload.filter) { $dialog.Filter = $Msg.payload.filter }
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                Send-ToJs -Type 'browse-result' -Payload @{
                    field = $Msg.payload.field; index = $Msg.payload.index; path = $dialog.FileName
                }
            }
        }
        'list-presets' {
            Send-ToJs -Type 'presets-found' -Payload ([array](Get-PresetsList))
        }
        'load-preset' {
            # fileName vem da propria lista que a gente mandou (list-presets)
            # ou do picker - Split-Path -Leaf descarta qualquer coisa antes
            # de uma barra que venha nesse campo, pra nunca ler fora de
            # PresetsDir por acidente.
            $fileName = Split-Path -Leaf $Msg.payload.fileName
            $path = Join-Path $script:PresetsDir $fileName
            try {
                $data = Get-Content -Raw -Path $path | ConvertFrom-Json
                Send-ToJs -Type 'preset-loaded' -Payload (Get-NormalizedPreset -Data $data)
            }
            catch {
                Send-ToJs -Type 'preset-loaded' -Payload @{ ok = $false; error = $_.Exception.Message }
            }
        }
        'browse-preset-file' {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Filter = 'Presets do Genesis (*.gnpreset)|*.gnpreset|Todos os arquivos (*.*)|*.*'
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                try {
                    $data = Get-Content -Raw -Path $dialog.FileName | ConvertFrom-Json
                    Send-ToJs -Type 'preset-loaded' -Payload (Get-NormalizedPreset -Data $data)
                }
                catch {
                    Send-ToJs -Type 'preset-loaded' -Payload @{ ok = $false; error = $_.Exception.Message }
                }
            }
        }
        'save-preset' {
            try {
                $preset = [pscustomobject]@{
                    genesisPreset = $true
                    version       = 1
                    name          = $Msg.payload.name
                    createdAt     = (Get-Date).ToString('o')
                    selectedApps  = [array]$Msg.payload.selectedApps
                    tasks         = $Msg.payload.tasks
                    extraApps     = [array]$Msg.payload.extraApps
                }
                $fileName = Get-PresetFileName -Name $Msg.payload.name
                $path = Join-Path $script:PresetsDir $fileName
                $preset | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding utf8
                Send-ToJs -Type 'preset-saved' -Payload @{ ok = $true; fileName = $fileName; name = $preset.name }
            }
            catch {
                Send-ToJs -Type 'preset-saved' -Payload @{ ok = $false; error = $_.Exception.Message }
            }
        }
        'window-close' {
            # X da titlebar manda {confirm:true}; o "Fechar" do fim do fluxo
            # nao manda nada (fecha direto, sem perguntar - ja e uma acao
            # deliberada no ultimo passo).
            if ($Msg.payload -and $Msg.payload.confirm) {
                $result = [System.Windows.Forms.MessageBox]::Show(
                    $form, 'Tem certeza que quer fechar o Genesis?', 'Genesis',
                    'YesNo', 'Question')
                if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            $form.Close()
        }
        'window-minimize' { $form.WindowState = 'Minimized' }
        'window-tray' {
            $script:trayIcon.Visible = $true
            try {
                $script:trayIcon.ShowBalloonTip(6000, 'Genesis', 'Instalando em segundo plano. Clique no icone da bandeja (ou "Mostrar icones ocultos", a seta ^ perto do relogio) pra abrir de novo.', [System.Windows.Forms.ToolTipIcon]::Info)
            }
            catch { }
            # NAO usa $form.Hide(): isso tira a janela da barra de tarefas
            # por completo, deixando o icone da bandeja como UNICA forma de
            # voltar - se ele falhar silenciosamente (Shell_NotifyIcon pode
            # falhar sem lancar excecao .NET nenhuma), o usuario fica sem
            # nenhum jeito de recuperar a janela. Minimizado, ela some da
            # tela mas continua um botao normal na barra de tarefas -
            # sempre tem como voltar, com ou sem o icone do tray funcionando.
            $form.WindowState = 'Minimized'
        }
        'window-drag' {
            [NativeDrag]::ReleaseCapture() | Out-Null
            [NativeDrag]::SendMessage($form.Handle, [NativeDrag]::WM_NCLBUTTONDOWN, [NativeDrag]::HTCAPTION, 0) | Out-Null
        }
    }
}

# ----------------------------------------------------- background install --

function Start-InstallRun {
    param($Payload)

    $runspace = [runspacefactory]::CreateRunspace()
    # STA: apps sem instalacao silenciosa (ver Install-WingetApps.ps1,
    # "noSilent") mostram um MessageBox de verdade nessa runspace em
    # segundo plano antes de abrir o instalador deles - MessageBox exige
    # apartamento STA pra funcionar (o default de CreateRunspace() e MTA).
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    $null = $ps.AddScript({
        param($Root, $TasksJson, $WingetSelectedIds, $WingetUninstallIds, $Queue)

        . (Join-Path $Root 'modules\Common.ps1')
        $Global:GenesisLogSink = { param($m) $Queue.Enqueue([pscustomobject]@{ Type = 'Log'; Message = $m }) }.GetNewClosure()
        $Global:GenesisStepSink = { param($k, $s) $Queue.Enqueue([pscustomobject]@{ Type = 'Step'; Key = $k; Status = $s }) }.GetNewClosure()
        $Global:GenesisAppSink = { param($id, $s) $Queue.Enqueue([pscustomobject]@{ Type = 'App'; Id = $id; Status = $s }) }.GetNewClosure()

        $logDir = Join-Path $Root 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $script:LogFile = Join-Path $logDir "genesis-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

        Get-ChildItem -Path (Join-Path $Root 'modules') -Filter '*.ps1' | Where-Object { $_.Name -ne 'Common.ps1' } |
            ForEach-Object { . $_.FullName }

        $tasks = $TasksJson | ConvertFrom-Json
        try {
            $result = Invoke-GenesisPipeline -Root $Root -Tasks $tasks -WingetSelectedIds $WingetSelectedIds -WingetUninstallIds $WingetUninstallIds
            $Queue.Enqueue([pscustomobject]@{
                Type = 'Done'; Results = $result.Results; Reboot = $result.RebootRecommended; LogFile = $script:LogFile
            })
        }
        catch {
            $Queue.Enqueue([pscustomobject]@{ Type = 'Log'; Message = "ERRO FATAL: $($_.Exception.Message)" })
            $Queue.Enqueue([pscustomobject]@{ Type = 'Done'; Results = @{}; Reboot = $false; LogFile = $script:LogFile })
        }
    })
    $null = $ps.AddArgument($Root).AddArgument(($Payload.tasks | ConvertTo-Json -Depth 6)).AddArgument([string[]]$Payload.selectedAppIds).AddArgument([string[]]$Payload.uninstallAppIds).AddArgument($queue)
    $null = $ps.BeginInvoke()

    $script:installPs = $ps
    $script:installRunspace = $runspace
}

# ------------------------------------------------------------ installed apps --
# `winget list` demora alguns segundos - roda em background (mesmo padrao do
# Start-AppSearch) pra nao travar a janela, e manda os ids instalados assim
# que terminar. O catalogo ja renderiza normal antes disso; os cards so
# ganham o estado "ja instalado" quando essa lista chegar.
function Start-InstalledAppsCheck {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    $null = $ps.AddScript({
        param($Queue)
        $ids = @()
        try {
            $raw = winget list --accept-source-agreements 2>&1 | Out-String
            $lines = ($raw -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch '^-+$' }
            foreach ($line in $lines) {
                if ($line -match '^\s*(Nome|Name)\s{2,}') { continue }
                # Nome/ID/Versao/... separados por 2+ espacos - so o ID (2a
                # coluna) importa aqui, pra cruzar com o catalogo.
                $fields = [regex]::Split($line.TrimEnd(), '\s{2,}')
                if ($fields.Count -ge 2 -and $fields[1].Trim()) { $ids += $fields[1].Trim() }
            }
        }
        catch { }
        $Queue.Enqueue([pscustomobject]@{ Type = 'InstalledApps'; Ids = @($ids) })
    })
    $null = $ps.AddArgument($queue)
    $null = $ps.BeginInvoke()
}

# ------------------------------------------------------------- live search --
# Runs on a background runspace too - `winget search` + a `winget show`
# per result + a favicon fetch easily takes several seconds, and this
# handler fires on the same thread that pumps the WebView2 UI, so doing
# it inline would freeze the whole window until it finished.

function Start-AppSearch {
    param([string]$Query)

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    $null = $ps.AddScript({
        param($Query, $Queue)

        # Antes: `winget search` (so nome/id/versao) + N `winget show` em
        # paralelo pra descricao/homepage + N favicons via Google s2/domain.
        # Trocado por winget.run (https://docs.winget.run) - API publica que
        # indexa o MESMO repositorio (winget-pkgs) e devolve tudo (nome,
        # descricao, homepage, icone) num JSON so. O `winget show` tinha um
        # problema real: os campos estendidos (Descricao, URL do Fornecedor)
        # vem de uma busca remota a parte que o proprio winget as vezes
        # corta/omite - confirmado rodando o MESMO pacote varias vezes e
        # recebendo respostas diferentes. Uma chamada HTTP com schema fixo
        # elimina essa flakiness e a raspagem de texto por completo.
        #
        # NAO usa Invoke-RestMethod/ConvertFrom-Json: a API do winget.run
        # manda CreatedAt/createdAt e UpdatedAt/updatedAt DUPLICADOS (mesmo
        # objeto, so a capitalizacao muda). O parser JSON do Windows
        # PowerShell 5.1 e case-INsensitive, entao trata isso como chave
        # repetida e falha silenciosamente em TODA busca (nao so "Figma") -
        # confirmado direto contra a API. JavaScriptSerializer e case-
        # sensitive, entao nao colide.
        $results = @()
        try {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = 20971520
            $uri = "https://api.winget.run/v2/packages?query=$([Uri]::EscapeDataString($Query))&take=6"
            $json = (Invoke-WebRequest -Uri $uri -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop).Content
            $data = $serializer.DeserializeObject($json)
            $results = @($data['Packages'] | Select-Object -First 6 | ForEach-Object {
                $latest = $_['Latest']
                $versions = $_['Versions']
                $id = $_['Id']
                $isStore = $id -match '^[A-Z0-9]{12}$'
                [pscustomobject]@{
                    id          = $id
                    label       = $latest['Name']
                    version     = if ($versions -and $versions.Count) { $versions[$versions.Count - 1] } else { '' }
                    description = $latest['Description']
                    homepage    = $latest['Homepage']
                    icon        = $_['IconUrl']
                    # Install-WingetApps.ps1 le esse campo pra escolher
                    # `--source msstore` vs `--source winget` na instalacao.
                    source      = if ($isStore) { 'msstore' } else { 'winget' }
                }
            })
        }
        catch { }

        $Queue.Enqueue([pscustomobject]@{ Type = 'SearchResults'; Results = $results })
    })
    $null = $ps.AddArgument($Query).AddArgument($queue)
    $null = $ps.BeginInvoke()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $item = $null
    while ($queue.TryDequeue([ref]$item)) {
        switch ($item.Type) {
            'Log' { Send-ToJs -Type 'log' -Payload $item.Message }
            'Step' {
                $script:lastResults[$item.Key] = ($item.Status -eq 'Ok')
                Send-ToJs -Type 'step' -Payload @{ key = $item.Key; status = $item.Status }
            }
            'Done' {
                $script:lastResults = $item.Results
                Send-ToJs -Type 'done' -Payload @{ reboot = [bool]$item.Reboot; logFile = $item.LogFile }
                if ($script:installPs) { $script:installPs.Dispose() }
                if ($script:installRunspace) { $script:installRunspace.Close() }
                # Instalacao terminou - se o usuario tinha minimizado pro
                # tray, mostra a janela de volta sozinho.
                if ($script:trayIcon.Visible) { Show-GenesisWindow }
            }
            'SearchResults' { Send-ToJs -Type 'search-results' -Payload $item.Results }
            'App' { Send-ToJs -Type 'app-status' -Payload @{ id = $item.Id; status = $item.Status } }
            'InstalledApps' { Send-ToJs -Type 'installed-apps' -Payload $item.Ids }
        }
    }
})
$timer.Start()

# ------------------------------------------------------------------- wire --

$webView.add_CoreWebView2InitializationCompleted({
    param($s, $e)
    if (-not $e.IsSuccess) {
        # 0x800700AA = ERROR_BUSY: a pasta de dados do WebView2
        # (%LOCALAPPDATA%\Genesis\WebView2) esta travada por OUTRA instancia
        # do Genesis (ou uma copia dele) ainda aberta - nao e falta de
        # runtime, e so nao dava pra saber isso da mensagem generica de
        # baixo.
        $msg = if ($e.InitializationException.HResult -eq -2147024726) {
            "Ja existe outra instancia do Genesis aberta (ou travada em segundo plano).`n`nFeche-a (Gerenciador de Tarefas, se preciso) e abra o Genesis de novo."
        }
        else {
            "WebView2 nao inicializou: $($e.InitializationException.Message)`n`nO Runtime do WebView2 (vem com o Windows 11) pode estar faltando."
        }
        [System.Windows.Forms.MessageBox]::Show($msg, 'Genesis', 'OK', 'Error')
        $form.Close()
        return
    }
    $webView.CoreWebView2.add_WebMessageReceived({
        # NEVER name this 2nd parameter $args: PowerShell already has an
        # automatic $args variable, and shadowing it here made the real
        # CoreWebView2WebMessageReceivedEventArgs object sporadically
        # come through as a raw Object[] instead - this is exactly the
        # "does not contain a method named TryGetWebMessageAsString" bug.
        param($sender, $webMsgArgs)
        try {
            $json = $webMsgArgs.TryGetWebMessageAsString()
            $msg = $json | ConvertFrom-Json
            Handle-Message -Msg $msg
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Erro processando mensagem da interface: $($_.Exception.Message)",
                'Genesis', 'OK', 'Warning')
        }
    })
})
$webView.Source = [Uri]::new($indexPath)

[void]$form.ShowDialog()
