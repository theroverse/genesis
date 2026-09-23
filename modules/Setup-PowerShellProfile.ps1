# Copies the tracked profile into $PROFILE (works for both Windows
# PowerShell 5.1 and PowerShell 7 - both are handled since $PROFILE
# resolves per-host).  Starship (the only external dependency the
# profile expects) is installed separately via winget.

# Junta ate 3 fontes num profile so, nessa ordem (quem vem depois "ganha"
# de quem vem antes se redefinir a mesma funcao/alias - semantica normal
# do PowerShell, nao um merge inteligente por linha):
#   1. o profile padrao do Genesis (SourceProfile, tracked no repo);
#   2. o que ja existir em $PROFILE nesta maquina (ex: de uma instalacao
#      anterior, ou algo que o usuario ja tinha antes do Genesis);
#   3. um arquivo adicional que o usuario apontar na etapa "Profile do
#      PowerShell" (ex: o profile de verdade dele, guardado num repo git
#      privado - e assim que o dono do Genesis usa o proprio profile sem
#      ele ir parar no repo publico).
# Secoes identicas (mesmo conteudo, ja incluido antes) sao puladas, pra
# rodar o Genesis de novo na mesma maquina nao duplicar tudo.
function Get-MergedProfileContent {
    param(
        [Parameter(Mandatory)][string]$SourceProfile,
        [string]$ExistingProfilePath,
        [string]$CustomProfilePath
    )

    if (-not (Test-Path $SourceProfile)) {
        throw "Profile de origem nao encontrado: $SourceProfile"
    }

    $sections = [ordered]@{}
    $sections['Genesis - profile padrao'] = (Get-Content -Raw -Path $SourceProfile).TrimEnd()

    if ($ExistingProfilePath -and (Test-Path $ExistingProfilePath)) {
        $existing = (Get-Content -Raw -Path $ExistingProfilePath).Trim()
        if ($existing -and $sections.Values -notcontains $existing) {
            $sections["Ja existia nesta maquina ($ExistingProfilePath)"] = $existing
        }
    }

    if ($CustomProfilePath) {
        if (-not (Test-Path $CustomProfilePath)) {
            throw "Arquivo de profile adicional nao encontrado: $CustomProfilePath"
        }
        $custom = (Get-Content -Raw -Path $CustomProfilePath).Trim()
        if ($custom -and $sections.Values -notcontains $custom) {
            $sections["Adicionado por voce ($CustomProfilePath)"] = $custom
        }
    }

    $bar = '#' + ('=' * 63)
    $blocks = foreach ($label in $sections.Keys) {
        "$bar`n# $label`n$bar`n`n$($sections[$label])`n"
    }
    return ($blocks -join "`n")
}

# Base do `goto`/`g` (funcao goto no profile): por padrao o profile usa
# "$project_path = $HOME", que so funciona se os projetos do usuario
# morarem debaixo do home. Quando informado (pasta de projetos escolhida
# na Revisao), o valor dinamico $HOME e trocado por esse caminho literal
# em TODA secao mesclada que tiver essa linha (a substituicao do
# -replace do PowerShell ja e global por padrao, diferente do .Replace()
# de string comum).
function Set-ProfileProjectPath {
    param([Parameter(Mandatory)][string]$Content, [string]$ProjectsPath)
    if (-not $ProjectsPath) { return $Content }
    $escaped = $ProjectsPath -replace "'", "''"
    return ($Content -replace '(?m)^\s*\$project_path\s*=\s*\$HOME\s*$', "    `$project_path = '$escaped'")
}

function Set-UserProfileScript {
    param(
        [Parameter(Mandatory)][string]$SourceProfile,
        [string]$ProjectsPath,
        [string]$CustomProfilePath
    )

    $content = Get-MergedProfileContent -SourceProfile $SourceProfile `
        -ExistingProfilePath $PROFILE.CurrentUserAllHosts -CustomProfilePath $CustomProfilePath
    $content = Set-ProfileProjectPath -Content $content -ProjectsPath $ProjectsPath

    $targets = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
    foreach ($target in $targets) {
        $dir = Split-Path -Parent $target
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -Path $target -Value $content -Encoding utf8 -Force
        Write-Ok "Profile copiado para $target"
    }

    if (-not (Test-CommandExists 'starship')) {
        Write-Warn2 "starship nao encontrado no PATH ainda (winget pode precisar de um novo terminal)"
    }
}
