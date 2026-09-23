# Installs apps from config/winget-apps.json via winget. Each catalog
# entry is { id, label, category, default, source?, extraArgs?, deelevate? }
# - "source" e so pra pacotes da Microsoft Store (ex: Netflix), que
# precisam de --source msstore em vez da fonte community padrao.
#
# -SelectedIds (passed by the wizard) installs exactly those ids,
# regardless of each entry's "default". Without it (plain console run
# via genesis.ps1), every entry with "default": true installs - the
# catalog IS the config in that mode.
#
# Skips ids already installed. Microsoft.Office e Canonical.Ubuntu.2204
# podem abrir a propria UI de instalador - esperado, nao e falha.
#
# -UninstallIds (vem do Catalogo, quando o usuario desmarca um app JA
# instalado e confirma no dialogo - ver openConfirmUninstall em app.js):
# roda ANTES dos installs, sao listas disjuntas por construcao (o app.js
# tira o id de SelectedIds assim que ele entra em UninstallIds).
#
# "extraArgs" (array): flags extras passadas direto pro winget install,
# alem do id - ex: Microsoft.Office usa ["--ignore-security-hash"] porque
# o bootstrapper deles no CDN muda mais rapido do que o manifesto da
# comunidade atualiza o hash SHA256, e o winget recusa por seguranca sem
# esse flag (confirmado: codigo de retorno -1978335215 =
# APPINSTALLER_CLI_ERROR_INSTALLER_HASH_MISMATCH). --ignore-security-hash
# em si e um recurso desligado por padrao no winget - precisa de
# `winget settings --enable InstallerHashOverride` rodado uma vez como
# Administrador antes, senao o proprio winget rejeita o flag como
# argumento invalido (codigo -1978335230 =
# APPINSTALLER_CLI_ERROR_INVALID_CL_ARGUMENTS, confirmado ao vivo - a
# mensagem de erro do winget literalmente diz isso). Install-WingetApps
# habilita essa configuracao sozinho antes do loop, se precisar.
#
# "deelevate" (bool): instala via Install-WingetAppDeelevated em vez do
# winget direto - pra apps cujo manifesto proibe instalacao elevada (ex:
# Spotify, codigo -1978335146 = APPINSTALLER_CLI_ERROR_INSTALLER_
# PROHIBITS_ELEVATION). Como o Genesis inteiro roda como Administrador,
# winget recusa esses OBRIGATORIAMENTE - nao existe flag de CLI que
# ignore essa checagem (confirmado no codigo-fonte/issues do winget-cli).
# A unica saida e rodar o winget install como o usuario logado, SEM o
# token elevado - ver Install-WingetAppDeelevated.
#
# "noSilent" (bool): o instalador NAO TEM modo silencioso nenhum (ex:
# Battle.net - confirmado no forum oficial da Blizzard: admins de TI
# pediram isso desde 2019, testaram todo parametro obvio, a Blizzard
# nunca implementou). Nao adianta tentar --silent nesses - a janela do
# instalador sempre abre esperando clique. Em vez de fingir que e
# automatico, esses ficam pro FINAL da fila e o Genesis avisa o usuario
# com um MessageBox antes de abrir a janela de cada um, e espera de
# verdade (sem matar por timeout) ate o usuario terminar.

# Roda winget.exe com timeout: alguns instaladores (Battle.net e o
# principal caso confirmado) sao bootstrappers que baixam o app de
# verdade e depois NUNCA terminam sozinhos - o client fica rodando pra
# sempre em segundo plano em vez do instalador sair. Sem limite de tempo,
# um app assim trava o pipeline inteiro pra sempre em "Instalando...".
# taskkill /T mata a arvore inteira de processos - Process.Kill() do
# .NET Framework (Windows PowerShell 5.1) so mata o processo pai, nao os
# filhos que o instalador pode ter soltado.
function Invoke-WingetTimed {
    param(
        [Parameter(Mandatory)][string[]]$ArgList,
        [int]$TimeoutSec = 900
    )
    $proc = Start-Process -FilePath 'winget.exe' -ArgumentList $ArgList -PassThru -WindowStyle Hidden
    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $proc.Id, '/T', '/F') -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $true }
    }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; TimedOut = $false }
}

function Install-WingetApps {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string[]]$SelectedIds,
        [string[]]$UninstallIds
    )

    if (-not (Test-CommandExists 'winget')) {
        Install-WingetIfMissing
    }
    if (-not (Test-CommandExists 'winget')) {
        throw "winget ainda nao encontrado apos tentar instalar automaticamente. Abra a Microsoft Store, atualize o 'App Installer' e rode de novo."
    }

    foreach ($id in $UninstallIds) {
        Write-AppStatus -Id $id -Status 'Running'
        Write-Host "    Desinstalando $id ..." -ForegroundColor DarkCyan
        $r = Invoke-WingetTimed -ArgList @('uninstall', '--id', $id, '--exact', '--silent', '--accept-source-agreements')
        if ($r.ExitCode -eq 0) {
            Write-Ok "$id desinstalado"
            Write-AppStatus -Id $id -Status 'Ok'
        }
        else {
            $why = if ($r.TimedOut) { 'excedeu o tempo limite' } else { "retornou codigo $($r.ExitCode)" }
            Write-Warn2 "$id (desinstalar) $why"
            Write-AppStatus -Id $id -Status 'Fail'
        }
    }

    $catalog = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
    $selected = if ($SelectedIds) {
        $catalog | Where-Object { $_.id -in $SelectedIds }
    }
    else {
        $catalog | Where-Object { $_.default }
    }
    # Apps sem instalacao silenciosa vao pro final da fila (ver o comentario
    # grande de "noSilent" no topo do arquivo) - instalar tudo que roda
    # sozinho primeiro, deixando a espera manual por ultimo.
    $apps = @($selected | Where-Object { -not $_.noSilent })
    $manualApps = @($selected | Where-Object { $_.noSilent })

    if ($apps | Where-Object { $_.extraArgs -contains '--ignore-security-hash' }) {
        winget settings --enable InstallerHashOverride | Out-Null
    }

    foreach ($app in $apps) {
        $id = $app.id
        $source = if ($app.source) { $app.source } else { 'winget' }
        $sourceArgs = @('--source', $source)
        $extraArgs = @($app.extraArgs)
        Write-AppStatus -Id $id -Status 'Running'

        $already = winget list --id $id --exact --accept-source-agreements @sourceArgs 2>$null |
            Select-String -SimpleMatch $id
        if ($already) {
            Write-Ok "$($app.label) ($id) ja instalado"
            Write-AppStatus -Id $id -Status 'Ok'
            continue
        }

        Write-Host "    Instalando $($app.label) ($id) ..." -ForegroundColor DarkCyan
        if ($app.deelevate) {
            $code = Install-WingetAppDeelevated -Id $id -SourceArgs $sourceArgs -ExtraArgs $extraArgs
            $timedOut = $false
        }
        else {
            $installArgs = @('install', '-e', '--id', $id, '--accept-source-agreements', '--accept-package-agreements', '--silent') + $sourceArgs + $extraArgs
            $r = Invoke-WingetTimed -ArgList $installArgs
            $code = $r.ExitCode
            $timedOut = $r.TimedOut
        }
        if ($code -eq 0) {
            Write-Ok "$($app.label) instalado"
            Write-AppStatus -Id $id -Status 'Ok'
        }
        else {
            $why = if ($timedOut) { 'excedeu o tempo limite (instalador pode nunca terminar sozinho - ver Battle.net)' } else { "retornou codigo $code" }
            Write-Warn2 "$($app.label) ($id) $why (pode precisar instalar manualmente)"
            Write-AppStatus -Id $id -Status 'Fail'
        }
    }

    if ($manualApps) {
        Install-WingetAppsManually -Apps $manualApps
    }
}

# Instala apps que NAO tem modo silencioso (ver "noSilent" no topo do
# arquivo) - avisa o usuario uma unica vez, em linguagem bem simples, e
# so entao abre a janela de instalacao de cada um, esperando de verdade
# ate o usuario terminar (sem timeout - e literalmente o usuario clicando
# "Avancar" que faz isso andar).
function Install-WingetAppsManually {
    param([Parameter(Mandatory)]$Apps)

    Add-Type -AssemblyName System.Windows.Forms

    $names = ($Apps | ForEach-Object { $_.label }) -join ', '
    $msg = @"
Alguns programas nao conseguem se instalar sozinhos: $names.

Daqui a pouco vai abrir a janela de instalacao de cada um, do mesmo jeito
que abre quando voce baixa e instala um programa manualmente.

E so ir clicando em "Avancar", "Instalar" ou "Concluir" ate a janela dele
fechar. O Genesis espera voce terminar cada um antes de continuar.

Clique OK para comecar.
"@
    [System.Windows.Forms.MessageBox]::Show($msg, 'Genesis - alguns programas precisam da sua ajuda', 'OK', 'Information') | Out-Null

    foreach ($app in $Apps) {
        $id = $app.id
        $source = if ($app.source) { $app.source } else { 'winget' }
        $sourceArgs = @('--source', $source)
        $extraArgs = @($app.extraArgs)
        Write-AppStatus -Id $id -Status 'Running'

        $already = winget list --id $id --exact --accept-source-agreements @sourceArgs 2>$null |
            Select-String -SimpleMatch $id
        if ($already) {
            Write-Ok "$($app.label) ($id) ja instalado"
            Write-AppStatus -Id $id -Status 'Ok'
            continue
        }

        Write-Host "    Instalando $($app.label) ($id) - aguardando voce terminar na janela dele ..." -ForegroundColor DarkCyan
        # --interactive (em vez de --silent): forca a janela do instalador
        # a aparecer de verdade. Start-Process -Wait sem timeout de
        # proposito aqui - o Genesis so segue quando o instalador de fato
        # sair (o usuario terminando ou fechando a janela).
        $installArgs = @('install', '-e', '--id', $id, '--accept-source-agreements', '--accept-package-agreements', '--interactive') + $sourceArgs + $extraArgs
        $proc = Start-Process -FilePath 'winget.exe' -ArgumentList $installArgs -PassThru -Wait
        if ($proc.ExitCode -eq 0) {
            Write-Ok "$($app.label) instalado"
            Write-AppStatus -Id $id -Status 'Ok'
        }
        else {
            Write-Warn2 "$($app.label) ($id) retornou codigo $($proc.ExitCode) (talvez a janela tenha sido fechada sem terminar)"
            Write-AppStatus -Id $id -Status 'Fail'
        }
    }
}

# Roda "winget install" como o usuario interativo logado, SEM o token
# elevado do processo do Genesis - via uma tarefa agendada de disparo
# unico (RunLevel Limited), o mesmo truque que ferramentas de deploy
# corporativas usam pra "descer" de admin. Sem isso, apps com
# ElevationRequirement: elevationProhibited no manifesto (ex: Spotify)
# SEMPRE falham quando o processo chamador (o Genesis inteiro) ja esta
# elevado - confirmado: nao ha flag de winget install que contorne essa
# checagem, so rodar de fato como processo nao-elevado resolve.
function Install-WingetAppDeelevated {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string[]]$SourceArgs,
        [string[]]$ExtraArgs
    )

    $taskName = "Genesis-Deelevate-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $wingetArgs = (@('install', '-e', '--id', $Id, '--accept-source-agreements', '--accept-package-agreements', '--silent') + $SourceArgs + $ExtraArgs) -join ' '

    # Caminho cheio, nao so "winget.exe": winget.exe e um App Execution
    # Alias (stub em %LOCALAPPDATA%\Microsoft\WindowsApps) - resolver pelo
    # nome bateu ERROR_FILE_NOT_FOUND (codigo 2147942402 = 0x80070002)
    # rodando dentro de uma tarefa agendada, mesmo pro mesmo usuario -
    # confirmado ao vivo. Caminho absoluto elimina a resolucao por PATH.
    $wingetPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (-not (Test-Path $wingetPath)) { $wingetPath = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source }
    if (-not $wingetPath) { $wingetPath = 'winget.exe' }

    $action = New-ScheduledTaskAction -Execute $wingetPath -Argument $wingetArgs
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        # nao ha "espera terminar" nativo pra Start-ScheduledTask - poll no
        # State ('Running' enquanto executa) ate parar ou estourar o tempo.
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 2
            $info = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } while ($info -and $info.State -eq 'Running' -and (Get-Date) -lt $deadline)

        $result = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        # LastTaskResult e um HRESULT igual ao que winget.exe retornaria
        # rodando direto - mesma leitura de codigo que o resto da funcao ja faz.
        return $result.LastTaskResult
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
