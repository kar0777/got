# Security / Безопасность

## Русский

GitLab Duo CLI Switcher работает с локальными Git-репозиториями, OAuth-конфигурациями `glab`, терминальными командами и локальными transcript. Относитесь к папке данных как к чувствительной.

### Безопасные настройки по умолчанию

- подтверждение инструментов включено;
- сырые VT-логи выключены;
- данные профилей разделены по отдельным каталогам;
- локальный recorder старается редактировать распространённые форматы токенов;
- конфигурация сохраняется атомарно с резервной копией;
- диагностика не должна отправлять данные автоматически.

### Что нельзя публиковать

Перед созданием issue, отправкой скриншота или журнала удалите:

- содержимое `config.yml` из папок профилей;
- OAuth-токены и cookies;
- API-ключи, `.env` и резервные коды;
- персональные данные;
- приватный исходный код;
- сырые VT-логи без ручной проверки.

### Где находятся чувствительные данные

```text
%LOCALAPPDATA%\GitLabDuoCLISwitcher
```

Особенно осторожно обращайтесь с подпапками `profiles` и `project-state`.

### Автоподтверждение команд

Режим автоматического подтверждения позволяет GitLab Duo выполнять команды и менять файлы без отдельного вопроса. Включайте его только:

- в доверенном проекте;
- после создания commit или backup;
- когда вы понимаете возможные команды агента;
- без административных секретов в рабочей папке.

### Сообщение об уязвимости

Не публикуйте рабочие секреты в открытом issue. Опишите проблему без токенов, приложите обезличенные шаги воспроизведения и укажите версию Switcher и Windows.

## English

GitLab Duo CLI Switcher handles local Git repositories, `glab` OAuth configuration, terminal commands, and local transcripts. Treat its data directory as sensitive.

### Safer defaults

- tool confirmation is enabled;
- raw VT logs are disabled;
- profile data is isolated in separate directories;
- the recorder attempts to redact common token formats;
- configuration writes are atomic and backed up;
- diagnostics should not upload data automatically.

### Never publish

Before opening an issue or sharing screenshots or logs, remove:

- profile `config.yml` contents;
- OAuth tokens and cookies;
- API keys, `.env` files, and recovery codes;
- personal data;
- private source code;
- raw VT logs that have not been reviewed manually.

### Sensitive data location

```text
%LOCALAPPDATA%\GitLabDuoCLISwitcher
```

Pay particular attention to the `profiles` and `project-state` directories.

### Command auto-approval

Auto-approval allows GitLab Duo to run commands and edit files without a separate prompt. Enable it only:

- in a trusted repository;
- after creating a commit or backup;
- when you understand the commands the agent may execute;
- when the workspace does not contain administrative secrets.

### Reporting a vulnerability

Do not publish live secrets in a public issue. Describe the problem without credentials, provide sanitized reproduction steps, and include the Switcher and Windows versions.
