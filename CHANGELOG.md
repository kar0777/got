# Changelog

[Русский](#русский) · [English](#english)

## Русский

### 8.3.2

Исправления совместимости Windows PowerShell 5.1 и устойчивости конфигурации:

- логические выражения больше не начинаются с отдельного оператора `-and`;
- `Test-Path` не используется как голая команда внутри `if`;
- пустые объекты `hooks.json` больше не вызывают ошибку в StrictMode;
- повреждённые и неполные `hooks.json` восстанавливаются с резервной копией;
- пустые и старые `profiles.json` корректно мигрируют;
- неправильный путь проекта больше не завершает Hub;
- `Run.cmd` проверяет PowerShell-синтаксис перед запуском и показывает строку ошибки.

Сохранённая оптимизация памяти 8.3:

- память формируется как `USER → RESPONSE`;
- удаляются спиннеры, меню и повторяющийся TUI-шум;
- bridge сохраняет последние полезные сессии и компактный контекст;
- `AGENTS.md` получает подготовленную память проекта;
- Hub и Doctor показывают состояние локальной памяти.

## English

### 8.3.2

Windows PowerShell 5.1 compatibility and configuration resilience fixes:

- logical expressions no longer start a line with a standalone `-and` operator;
- `Test-Path` is no longer used as a bare command inside `if`;
- empty `hooks.json` objects no longer fail under StrictMode;
- damaged or incomplete `hooks.json` files are recovered with a backup;
- empty and legacy `profiles.json` files migrate safely;
- an invalid project path no longer terminates the Hub;
- `Run.cmd` validates PowerShell syntax before launch and reports the failing line.

Memory optimization from 8.3 remains enabled:

- memory is structured as `USER → RESPONSE`;
- spinners, menus, and repeated TUI noise are removed;
- the bridge keeps recent useful sessions and compact context;
- `AGENTS.md` receives prepared project memory;
- the Hub and Doctor show local memory health.
