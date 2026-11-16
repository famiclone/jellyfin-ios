# Jellyfin Desktop для iPadOS 15+ (адаптовано під iPad Air 2 / iPadOS 15.8.8)

Нативний iOS/iPadOS порт архітектури [`jellyfin/jellyfin-desktop`](https://github.com/jellyfin/jellyfin-desktop), створений спеціально для роботи на **iPad Air 2 (Apple A8X, 2 ГБ ОЗП, iPadOS 15.8.8)** та новіших пристроях з iOS/iPadOS 15.0+.

## Як це працює

Офіційний десктопний `jellyfin-desktop` використовує `Qt6 WebEngine` (Chromium), який фізично не існує на iOS, та `QWebChannel` + `libmpv`. Цей порт відтворює ту саму двошарову архітектуру засобами iOS 15 SDK:

1. **Нижній нативний відео-шар (`MobileVLCKit 3.6.0` / `libVLC`)**:
   - **Direct Play** без транскодингу на сервері для контейнерів **MKV, MP4, WebM, AVI**;
   - Апаратне декодування **H.264 через Apple VideoToolbox** на чипі A8X + багатопотокове програмне декодування FFmpeg (ARM64 NEON);
   - Повна підтримка субтитрів **ASS / SSA** (через `libass` зі стилями та вбудованими шрифтами), **SRT, PGS, VobSub** (як вбудованих у MKV, так і зовнішніх з Jellyfin) + налаштування затримки субтитрів;
   - Пряме декодування **FLAC, AC3, E-AC3, DTS, Opus, Vorbis, AAC, MP3**.
2. **Верхній прозорий шар інтерфейсу (`WKWebView` + `NativeShell` з `jellyfin-desktop`)**:
   - Інжектить оригінальні розширення `jellyfin-desktop` (`mpvVideoPlayer.js`, `mpvAudioPlayer.js`, `inputPlugin.js`, `nativeshell.js`) через двосторонній міст `WKScriptMessageHandler` (`iosWebChannelShim.js`, сумісний із `QWebChannel`);
   - Включає набір **ES2023/ES2024 поліфілів (`ios15Polyfills.js`)**, щоб сучасні версії `jellyfin-web` (10.9 / 10.10 / 10.11+) коректно працювали на WebKit iPadOS 15.8.8;
   - Повна інтеграція з системним плеєром iPadOS (**Lock Screen, Control Center, навушники AirPods / Bluetooth**, клавіатурні скорочення iPad).

---

## Як зібрати `.ipa` через GitHub Actions (без локального Xcode)

1. Створіть новий репозиторій на GitHub (можна приватний або публічний).
2. Відправте цей проєкт у репозиторій:
   ```bash
   git init
   git add .
   git commit -m "Initial Jellyfin Desktop iOS 15 port"
   git branch -M main
   git remote add origin https://github.com/<ВАШ_ЛОГІН>/<НАЗВА_РЕПО>.git
   git push -u origin main
   ```
3. Перейдіть у вкладку **Actions** вашого репозиторію на GitHub — автоматично запуститься workflow **Build Jellyfin Desktop iOS (.ipa)** (триває ~4–6 хвилин першого разу, далі ~1.5–2 хв завдяки кешуванню `MobileVLCKit`).
4. Відкрийте завершений білд і внизу в секції **Artifacts** завантажте архів **`JellyfinDesktop-iPadOS15-IPA`**, всередині якого будуть два файли:
   - `JellyfinDesktop-iOS15-unsigned.ipa` — для **Sideloadly / AltStore / SideStore / Feather**;
   - `JellyfinDesktop-iOS15-TrollStore.tipa` — для **TrollStore**.

---

## Як встановити на iPad Air 2 (iPadOS 15.8.8)

### Спосіб 1: Sideloadly або AltStore (без джейлбрейку, зі звичайним Apple ID)
1. Встановіть [Sideloadly](https://sideloadly.io/) на ваш Mac.
2. Підключіть iPad Air 2 кабелем, перетягніть `JellyfinDesktop-iOS15-unsigned.ipa` у вікно Sideloadly, введіть свій Apple ID та натисніть **Start**.
3. На iPad перейдіть у **Параметри -> Загальні -> VPN і керування пристроєм** та натисніть **Довіряти** для вашого профілю розробника.
4. Увімкніть доступ до **Локальної мережі** при першому запуску додатка, щоб клієнт міг бачити ваш домашній сервер Jellyfin (`192.168.x.x:8096`).

### Спосіб 2: TrollStore (безстроково без 7-денного перепідписування)
Прошивка **iPadOS 15.8.8 на iPad Air 2** підтримує встановлення через **TrollStore**. Якщо у вас встановлений TrollStore:
1. Перекиньте `JellyfinDesktop-iOS15-TrollStore.tipa` (або `.ipa`) на iPad через AirDrop / Файли.
2. Поділіться файлом у **TrollStore** -> натисніть **Install**. Додаток працюватиме постійно без перепідписування.

---

## Поради та керування на iPad Air 2 (Apple A8X)

- **Налаштування профілю кодеків під A8X**: у меню Jellyfin відкрийте **Профіль користувача -> Client Settings**. За замовчуванням увімкнено оптимальні налаштування для A8X:
  - **H.264 (до 1080p) у MKV/MP4 + ASS/SRT + FLAC/AC3** грає у режимі **Direct Play** апаратно через VideoToolbox із мінімальним споживанням батареї.
  - Прапорці **Force Transcode HEVC / 4K / Hi10P / HDR / AV1** увімкнені, щоб важкі 10-бітні 4K HEVC файли сервер автоматично транскодував у легкий H.264. Якщо ви хочете програвати легкі 720p/1080p 8-bit HEVC або 10-bit H.264 аніме напряму процесором iPad — просто зніміть відповідну галочку в **Client Settings**.
- **Масштабування під екран 4:3 (Zoom / Fit)**: під час перегляду відео натисніть іконку шестерні в плеєрі Jellyfin -> **Aspect Ratio -> Zoom**, щоб розгорнути 16:9 відео на весь 4:3 екран iPad без чорних смуг.
- **Швидке сервісне меню жестом**: затисніть екран **трьома пальцями на 1 секунду** будь-де в додатку — відкриється нативне меню iPadOS, де можна:
  - оновити сторінку;
  - перемкнути режим інтерфейсу (`DESKTOP` / `MOBILE` / `TV`);
  - увімкнути довіру до самопідписаного SSL-сертифіката;
  - скинути збережений сервер і повернутися на екран вводу IP-адреси.
