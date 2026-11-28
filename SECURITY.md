# Security policy · Политика безопасности

## Supported versions

Only the latest release from [Releases](https://github.com/CyberCat2033/AntiRKN/releases/latest) and the matching `antirkn-runner` receive security fixes. Update before reporting.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub private reporting: the repository's **Security** tab → **Report a vulnerability**.

Please include:

- the app version and platform (Android / Windows / Linux), and the runner version if the server side is involved;
- what an attacker can do and what they need for it;
- steps to reproduce or a proof of concept.

Never send real secrets: SSH keys, passwords, server addresses, OAuth tokens, workspace exports or client profiles. Replace them with placeholders.

You will get a reply when the report has been reviewed. Once a fix is released, the issue is disclosed in the changelog; credit is given if you want it.

## Scope

In scope: the app, `antirkn-runner`, the update and release chain, profile compilation and synchronization. Out of scope: vulnerabilities in third-party software the app installs (Xray, 3x-ui, AmneziaWG, TrustTunnel, Mihomo); report those to their authors.

---

## Поддерживаемые версии

Исправления безопасности выходят только для последнего релиза из [Releases](https://github.com/CyberCat2033/AntiRKN/releases/latest) и соответствующей версии `antirkn-runner`. Перед сообщением обновитесь.

## Как сообщить об уязвимости

**Не открывайте публичный issue.** Используйте приватное сообщение GitHub: вкладка **Security** репозитория → **Report a vulnerability**.

Укажите версию приложения и платформу (а если затронут сервер — версию runner), что может сделать атакующий и что ему для этого нужно, шаги воспроизведения или proof of concept.

Не присылайте настоящие секреты: SSH-ключи, пароли, адреса серверов, OAuth-токены, экспорт рабочего пространства или клиентские профили. Заменяйте их заглушками.

Ответ придёт после разбора сообщения. После выпуска исправления уязвимость описывается в changelog, по желанию упоминаем автора сообщения.

Уязвимости стороннего ПО, которое ставит приложение (Xray, 3x-ui, AmneziaWG, TrustTunnel, Mihomo), сообщайте их авторам.
