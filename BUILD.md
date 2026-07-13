# Build the distribution / Сборка архива

## Русский

Исходный ZIP сохранён в репозитории безопасными текстовыми частями в каталоге `package-parts/`. Workflow собирает из них оригинальный архив и распаковывает просматриваемые исходники в `src/`.

### Через GitHub Actions

1. Откройте вкладку **Actions** репозитория.
2. Если GitHub предлагает включить workflows, нажмите **I understand my workflows, go ahead and enable them**.
3. Выберите workflow **Assemble distribution package**.
4. Нажмите **Run workflow** → **Run workflow**.
5. После завершения workflow в ветке `main` появятся:
   - `dist/GitLabDuoCLI-Switcher-v8.3.2.zip`;
   - `dist/SHA256SUMS.txt`;
   - четыре исходных файла в `src/`.

### Локально в PowerShell

```powershell
$parts = Get-ChildItem ".\package-parts\GitLabDuoCLI-Switcher-v8.3.2.zip.b64.part-*" |
    Sort-Object Name

$base64 = ($parts | ForEach-Object { Get-Content $_.FullName -Raw }) -join ""
New-Item -ItemType Directory -Force ".\dist" | Out-Null
[IO.File]::WriteAllBytes(
    ".\dist\GitLabDuoCLI-Switcher-v8.3.2.zip",
    [Convert]::FromBase64String(($base64 -replace "\s", ""))
)

Expand-Archive ".\dist\GitLabDuoCLI-Switcher-v8.3.2.zip" ".\dist\unpacked" -Force
```

## English

The original ZIP is stored as repository-safe text parts under `package-parts/`. The workflow reconstructs the original archive and extracts browsable source files into `src/`.

### GitHub Actions

1. Open the repository **Actions** tab.
2. If GitHub asks to enable workflows, select **I understand my workflows, go ahead and enable them**.
3. Select **Assemble distribution package**.
4. Choose **Run workflow** → **Run workflow**.
5. When it finishes, `main` will contain:
   - `dist/GitLabDuoCLI-Switcher-v8.3.2.zip`;
   - `dist/SHA256SUMS.txt`;
   - the four browsable source files under `src/`.

### Local PowerShell build

```powershell
$parts = Get-ChildItem ".\package-parts\GitLabDuoCLI-Switcher-v8.3.2.zip.b64.part-*" |
    Sort-Object Name

$base64 = ($parts | ForEach-Object { Get-Content $_.FullName -Raw }) -join ""
New-Item -ItemType Directory -Force ".\dist" | Out-Null
[IO.File]::WriteAllBytes(
    ".\dist\GitLabDuoCLI-Switcher-v8.3.2.zip",
    [Convert]::FromBase64String(($base64 -replace "\s", ""))
)

Expand-Archive ".\dist\GitLabDuoCLI-Switcher-v8.3.2.zip" ".\dist\unpacked" -Force
```
