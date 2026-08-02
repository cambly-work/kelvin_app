#!/bin/bash
# clean-old-version.sh — безопасная очистка старой установленной версии
# Kelvin / BatteryMeter и её служб перед чистой установкой новой версии.
#
# Обычный режим (без флагов): удаляет только установленные системой объекты —
# app bundle, launchd-службы и их payload. Пользовательские данные
# (настройки, профили, CrashReports, keychain, TCC) СОХРАНЯЮТСЯ.
#
# Флаги:
#   --dry-run           только показать, что было бы сделано; ничего не меняет,
#                       не вызывает sudo / launchctl / pkill.
#   --purge-user-data   дополнительно удалить пользовательские данные Kelvin.
#                       Требует интерактивного подтверждения (или --yes).
#   --yes               подтвердить purge без диалога (для автоматизации).
#   --help, -h          эта справка.
#
# Поведение по привилегиям: пользовательская часть выполняется от текущего
# пользователя; sudo запрашивается ровно для системной части и только если есть
# root-объекты. Несколько списков путей НЕ разводим — allowlist определён здесь.
#
# НЕ запускайте весь скрипт через sudo — он сам запросит права для нужных шагов.

set -euo pipefail

# ───────────────────────── аргументы ─────────────────────────
DRY_RUN=0
PURGE=0
ASSUME_YES=0
SHOW_HELP=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)         DRY_RUN=1 ;;
        --purge-user-data) PURGE=1 ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --help|-h)         SHOW_HELP=1 ;;
        *) echo "✗ Неизвестный аргумент: $arg (см. --help)" >&2; exit 2 ;;
    esac
done

if [ "$SHOW_HELP" = "1" ]; then
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit 0
fi

# ───────────────────────── тестовый корень (недокументирован, только для тестов) ─────────────────────────
# KELVIN_TEST_ROOT перенаправляет файловые операции в песочницу и отключает
# pkill/launchctl/sudo. Production обязана отвергать опасные/пустые значения.
TEST_ROOT=""
LIVE_LAUNCHCTL=1
if [ -n "${KELVIN_TEST_ROOT:-}" ]; then
    case "$KELVIN_TEST_ROOT" in
        ""|"/"|"/Library"|"/Applications"|"/System"|"/Users"|"/var"|"/private"|"/etc"|"$HOME")
            echo "✗ KELVIN_TEST_ROOT имеет опасное значение; отказ." >&2; exit 2 ;;
    esac
    case "$KELVIN_TEST_ROOT" in
        /*) ;;                                  # абсолютный — ок
        *)  echo "✗ KELVIN_TEST_ROOT должен быть абсолютным путём." >&2; exit 2 ;;
    esac
    case "$KELVIN_TEST_ROOT" in
        *..*) echo "✗ KELVIN_TEST_ROOT не должен содержать '..'." >&2; exit 2 ;;
    esac
    TEST_ROOT="$KELVIN_TEST_ROOT"
    LIVE_LAUNCHCTL=0                            # в песочнике launchd/pkill/sudo не трогаем
fi

# ───────────────────────── префиксы путей ─────────────────────────
if [ -n "$TEST_ROOT" ]; then
    APPS_DIR="$TEST_ROOT/Applications"
    SYS_LAUNCHDAEMONS="$TEST_ROOT/Library/LaunchDaemons"
    SYS_APP_SUPPORT="$TEST_ROOT/Library/Application Support"
    PRIV_HELPER_TOOLS="$TEST_ROOT/Library/PrivilegedHelperTools"
    USER_HOME="$TEST_ROOT/home"
    USER_LAUNCHAGENTS="$USER_HOME/Library/LaunchAgents"
    USER_APP_SUPPORT="$USER_HOME/Library/Application Support"
    USER_PREFS="$USER_HOME/Library/Preferences"
else
    APPS_DIR="/Applications"
    SYS_LAUNCHDAEMONS="/Library/LaunchDaemons"
    SYS_APP_SUPPORT="/Library/Application Support"
    PRIV_HELPER_TOOLS="/Library/PrivilegedHelperTools"
    USER_HOME="$HOME"
    USER_LAUNCHAGENTS="$HOME/Library/LaunchAgents"
    USER_APP_SUPPORT="$HOME/Library/Application Support"
    USER_PREFS="$HOME/Library/Preferences"
fi
SYS_KELVIN_SUPPORT="$SYS_APP_SUPPORT/Kelvin"
SYS_BATTERY_SUPPORT="$SYS_APP_SUPPORT/BatteryMeter"
UID_NUM="$(id -u)"

# ───────────────────────── allowlist (разрешённые destructive-цели) ─────────────────────────
# Только эти пути могут быть удалены. Любой другой путь → отказ. Никаких globs.
ALLOWED_FILES=(
    # app bundles
    "$APPS_DIR/Kelvin.app"
    "$APPS_DIR/BatteryMeter.app"
    # user LaunchAgents
    "$USER_LAUNCHAGENTS/com.local.batterymeter.plist"
    "$USER_LAUNCHAGENTS/com.trykelvin.kelvin.login.plist"
    # system LaunchDaemon plists
    "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.powerd.plist"
    "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.fand.plist"
    "$SYS_LAUNCHDAEMONS/com.local.batterymeter.powerd.plist"
    "$SYS_LAUNCHDAEMONS/com.local.batterymeter.fand.plist"
    "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.privileged.plist"
    # system Kelvin payload (точечные файлы, не каталог целиком)
    "$SYS_KELVIN_SUPPORT/kelvin-powerd.sh"
    "$SYS_KELVIN_SUPPORT/kelvin-powerd.sh.version"
    "$SYS_KELVIN_SUPPORT/power.txt"
    "$SYS_KELVIN_SUPPORT/power.txt.tmp"
    "$SYS_KELVIN_SUPPORT/powermetrics.err"
    "$SYS_KELVIN_SUPPORT/kelvin-fand"
    "$SYS_KELVIN_SUPPORT/kelvin-fand.version"
    # legacy privileged helper (macOS 11–12, SMJobBless)
    "$PRIV_HELPER_TOOLS/com.trykelvin.kelvin.privileged"
)
# recursive-цели (rm -rf): только целые каталоги из явного списка.
ALLOWED_DIRS=(
    "$APPS_DIR/Kelvin.app"
    "$APPS_DIR/BatteryMeter.app"
    "$SYS_BATTERY_SUPPORT"                      # legacy каталог — удаляем целиком
)
# rmdir-цели (только если пуст; никогда rm -rf).
ALLOWED_RMDIR=(
    "$SYS_KELVIN_SUPPORT"
)
# purge-цели (только при --purge-user-data).
ALLOWED_PURGE_FILES=(
    "$USER_PREFS/com.trykelvin.kelvin.plist"
)
ALLOWED_PURGE_DIRS=(
    "$USER_APP_SUPPORT/Kelvin"
)
PURGE_KEYCHAIN_SERVICE="com.trykelvin.crashreportstore"

# опасные корневые префиксы — rm-цель никогда не должна ими быть
DANGER_PREFIXES=(/ /System /usr /bin /sbin /etc /var /private/var /dev /proc)

is_allowed_file() {
    local t="$1"
    [ -n "$t" ] && [ "$t" != "/" ] || return 1
    for d in "${DANGER_PREFIXES[@]}"; do [ "$t" = "$d" ] && return 1; done
    local a
    for a in "${ALLOWED_FILES[@]}" "${ALLOWED_PURGE_FILES[@]}"; do [ "$t" = "$a" ] && return 0; done
    return 1
}
is_allowed_dir() {
    local t="$1"
    [ -n "$t" ] && [ "$t" != "/" ] || return 1
    for d in "${DANGER_PREFIXES[@]}"; do [ "$t" = "$d" ] && return 1; done
    local a
    for a in "${ALLOWED_DIRS[@]}" "${ALLOWED_PURGE_DIRS[@]}"; do [ "$t" = "$a" ] && return 0; done
    return 1
}
is_allowed_rmdir() {
    local t="$1"
    [ -n "$t" ] && [ "$t" != "/" ] || return 1
    local a
    for a in "${ALLOWED_RMDIR[@]}"; do [ "$t" = "$a" ] && return 0; done
    return 1
}

# ───────────────────────── учёт результатов ─────────────────────────
declare -a REPORT_REMOVED=() REPORT_MISSING=() REPORT_PURGE=() REPORT_ERRORS=() REPORT_KEPT=()
note_removed() { REPORT_REMOVED+=("$1"); }
note_missing() { REPORT_MISSING+=("$1"); }
note_purge()   { REPORT_PURGE+=("$1"); }
note_error()   { REPORT_ERRORS+=("$1"); }
note_kept()    { REPORT_KEPT+=("$1"); }

# ───────────────────────── вывод / выполнение ─────────────────────────
say()  { printf '%s\n' "$*"; }
would(){ [ "$DRY_RUN" = "1" ] && say "  [dry-run] $*" || true; }
fail() { echo "✗ $*" >&2; note_error "$*"; }

# выполнить команду от root (sudo точечно; в тестовом режиме — без sudo)
root_run() {
    if [ "$DRY_RUN" = "1" ]; then would "sudo $*"; return 0; fi
    if [ "$LIVE_LAUNCHCTL" = "1" ] && [ "$(id -u)" != "0" ]; then
        sudo "$@"
    else
        "$@"
    fi
}
# команда launchd/pkill — только в production, в тесте/драй-ране печатаем.
# launchctl для системных демонов требует root — при необходимости оборачиваем в sudo.
live() {  # live <описание> <команда> [аргументы...]
    local desc="$1"; shift
    if [ "$DRY_RUN" = "1" ] || [ "$LIVE_LAUNCHCTL" = "0" ]; then would "$desc"; return 0; fi
    if [ "$(id -u)" != "0" ]; then
        sudo "$@" 2>/dev/null || true
    else
        "$@" 2>/dev/null || true
    fi
}

# безопасные операции удаления (каждая — с allowlist-проверкой)
rm_file() {  # rm_file <путь>
    local p="$1"
    if ! is_allowed_file "$p"; then fail "отказ в удалении (нет в allowlist): $p"; return 1; fi
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then note_missing "$p"; return 0; fi
    if [ "$DRY_RUN" = "1" ]; then would "rm -f $p"; return 0; fi
    if [ -d "$p" ] && [ ! -L "$p" ]; then fail "не файл, пропуск: $p"; return 1; fi
    if rm -f -- "$p"; then note_removed "$p"; else fail "не удалось удалить: $p"; return 1; fi
}
rm_dir() {  # rm_dir <путь>   (recursive — только для каталогов из ALLOWED_DIRS)
    local p="$1"
    if ! is_allowed_dir "$p"; then fail "отказ в удалении (нет в allowlist dir): $p"; return 1; fi
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then note_missing "$p"; return 0; fi
    if [ "$DRY_RUN" = "1" ]; then would "rm -rf $p"; return 0; fi
    if rm -rf -- "$p"; then note_removed "$p"; else fail "не удалось удалить: $p"; return 1; fi
}
rm_dir_if_empty() {  # rm_dir_if_empty <путь>   (rmdir, только из ALLOWED_RMDIR)
    local p="$1"
    if ! is_allowed_rmdir "$p"; then fail "отказ в rmdir (нет в allowlist): $p"; return 1; fi
    if [ ! -d "$p" ]; then note_missing "$p"; return 0; fi
    if [ "$DRY_RUN" = "1" ]; then would "rmdir $p"; return 0; fi
    if rmdir -- "$p" 2>/dev/null; then note_removed "$p (был пуст)"; else note_kept "$p (не пуст — сохранён)"; fi
}

# ───────────────────────── существование системных объектов ─────────────────────────
sys_targets_exist() {
    [ -e "$APPS_DIR/Kelvin.app" ] && return 0
    [ -e "$APPS_DIR/BatteryMeter.app" ] && return 0
    local f
    for f in \
        "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.powerd.plist" \
        "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.fand.plist" \
        "$SYS_LAUNCHDAEMONS/com.local.batterymeter.powerd.plist" \
        "$SYS_LAUNCHDAEMONS/com.local.batterymeter.fand.plist" \
        "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.privileged.plist" \
        "$SYS_BATTERY_SUPPORT" \
        "$PRIV_HELPER_TOOLS/com.trykelvin.kelvin.privileged" \
        "$SYS_KELVIN_SUPPORT/kelvin-powerd.sh" \
        "$SYS_KELVIN_SUPPORT/kelvin-fand"; do
        [ -e "$f" ] && return 0
    done
    return 1
}
sys_services_loaded() {
    # проверка только в production; в тесте/драй-ране считаем, что могут быть загружены
    [ "$LIVE_LAUNCHCTL" = "1" ] || return 0
    local lbl
    for lbl in \
        com.trykelvin.kelvin.powerd com.trykelvin.kelvin.fand \
        com.local.batterymeter.powerd com.local.batterymeter.fand \
        com.trykelvin.kelvin.privileged; do
        launchctl print "system/$lbl" >/dev/null 2>&1 && return 0
    done
    return 1
}

# ═════════════════════════ ФАЗА 1: пользовательская (от текущего пользователя) ═════════════════════════
phase_user() {
    say "→ Пользовательская часть…"

    # процессы
    if [ "$LIVE_LAUNCHCTL" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            would "pkill -x Kelvin / BatteryMeter"
        else
            pkill -x Kelvin 2>/dev/null || true
            pkill -x BatteryMeter 2>/dev/null || true
            note_removed "процессы Kelvin/BatteryMeter (остановлены, если были)"
        fi
    fi

    # пользовательские LaunchAgents (домен gui/$UID)
    for spec in \
        "com.local.batterymeter:$USER_LAUNCHAGENTS/com.local.batterymeter.plist" \
        "com.trykelvin.kelvin.login:$USER_LAUNCHAGENTS/com.trykelvin.kelvin.login.plist"; do
        local label="${spec%%:*}"
        local plist="${spec#*:}"
        if [ "$LIVE_LAUNCHCTL" = "1" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                would "launchctl bootout gui/$UID_NUM/$label ; unload $plist"
            else
                launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
                launchctl unload "$plist" 2>/dev/null || true
            fi
        fi
        rm_file "$plist" || true
    done
}

# ═════════════════════════ ФАЗА 2: системная (root) ═════════════════════════
phase_system() {
    # нужен root? (только если есть системные объекты или загруженные службы)
    local need_root=0
    sys_targets_exist && need_root=1
    sys_services_loaded && need_root=1
    if [ "$DRY_RUN" = "1" ]; then
        need_root=1     # чтобы показать системный план
    fi
    [ "$need_root" = "1" ] || { say "→ Системная часть: объектов не найдено — sudo не требуется."; return 0; }

    say "→ Системная часть…"
    if [ "$DRY_RUN" = "0" ] && [ "$LIVE_LAUNCHCTL" = "1" ] && [ "$(id -u)" != "0" ]; then
        say "  Запрашиваю права администратора для системной части…"
        sudo -v || { fail "не получены права администратора"; return 1; }
    fi

    # 1) ОСТАНОВКА СЛУЖБ — ДО удаления bundle. Важно для privileged (KeepAlive).
    say "  Останавливаю launchd-службы…"

    # privileged GPU-демон (SMAppService, macOS 13+): из shell доступен только bootout.
    # Полная дерегистрация требует SMAppService.unregister() из приложения; без него —
    # рекомендован перезагруз после удаления bundle (см. отчёт).
    live "launchctl bootout system/com.trykelvin.kelvin.privileged" launchctl bootout system/com.trykelvin.kelvin.privileged
    # legacy (macOS 11–12) — полноценные launchd-задачи:
    live "launchctl bootout system/com.trykelvin.kelvin.powerd"     launchctl bootout system/com.trykelvin.kelvin.powerd
    live "launchctl bootout system/com.local.batterymeter.powerd"   launchctl bootout system/com.local.batterymeter.powerd
    live "launchctl bootout system/com.trykelvin.kelvin.fand"       launchctl bootout system/com.trykelvin.kelvin.fand
    live "launchctl bootout system/com.local.batterymeter.fand"     launchctl bootout system/com.local.batterymeter.fand
    # fallback unload по путям (старые macOS / чужие установки)
    live "launchctl unload $SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.powerd.plist"   launchctl unload "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.powerd.plist"
    live "launchctl unload $SYS_LAUNCHDAEMONS/com.local.batterymeter.powerd.plist" launchctl unload "$SYS_LAUNCHDAEMONS/com.local.batterymeter.powerd.plist"
    live "launchctl unload $SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.fand.plist"     launchctl unload "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.fand.plist"
    live "launchctl unload $SYS_LAUNCHDAEMONS/com.local.batterymeter.fand.plist"   launchctl unload "$SYS_LAUNCHDAEMONS/com.local.batterymeter.fand.plist"
    live "launchctl unload $SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.privileged.plist" launchctl unload "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.privileged.plist"

    # fand: дать SIGTERM-обработчику восстановить вентиляторы в auto (как в uninstall-fan-helper.sh)
    if [ "$DRY_RUN" = "0" ]; then sleep 1; else would "sleep 1 (восстановление вентиляторов)"; fi

    # 2) УДАЛЕНИЕ BUNDLE — после остановки служб (иначе KeepAlive respawn по отсутствующему пути)
    say "  Удаляю установленные приложения…"
    rm_dir "$APPS_DIR/Kelvin.app" || true
    rm_dir "$APPS_DIR/BatteryMeter.app" || true

    # 3) УДАЛЕНИЕ PLIST И PAYLOAD (system, allowlisted)
    say "  Удаляю launchd-конфиги и payload…"
    rm_file "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.powerd.plist" || true
    rm_file "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.fand.plist" || true
    rm_file "$SYS_LAUNCHDAEMONS/com.local.batterymeter.powerd.plist" || true
    rm_file "$SYS_LAUNCHDAEMONS/com.local.batterymeter.fand.plist" || true
    rm_file "$SYS_LAUNCHDAEMONS/com.trykelvin.kelvin.privileged.plist" || true  # legacy 11–12
    rm_file "$PRIV_HELPER_TOOLS/com.trykelvin.kelvin.privileged" || true         # legacy 11–12

    rm_file "$SYS_KELVIN_SUPPORT/kelvin-powerd.sh" || true
    rm_file "$SYS_KELVIN_SUPPORT/kelvin-powerd.sh.version" || true
    rm_file "$SYS_KELVIN_SUPPORT/power.txt" || true
    rm_file "$SYS_KELVIN_SUPPORT/power.txt.tmp" || true
    rm_file "$SYS_KELVIN_SUPPORT/powermetrics.err" || true
    rm_file "$SYS_KELVIN_SUPPORT/kelvin-fand" || true
    rm_file "$SYS_KELVIN_SUPPORT/kelvin-fand.version" || true

    # legacy каталог BatteryMeter — целиком
    rm_dir "$SYS_BATTERY_SUPPORT" || true

    # системный Kelvin-каталог — только если пуст (никогда rm -rf)
    rm_dir_if_empty "$SYS_KELVIN_SUPPORT" || true
}

# ═════════════════════════ ФАЗА 3: purge пользовательских данных (опционально) ═════════════════════════
phase_purge() {
    [ "$PURGE" = "1" ] || return 0

    say "→ Полное удаление пользовательских данных (--purge-user-data)…"
    say "  Будут удалены:"
    say "    • $USER_PREFS/com.trykelvin.kelvin.plist"
    say "    • $USER_APP_SUPPORT/Kelvin  (профили, CrashReports и т.д.)"
    say "    • keychain-запись сервиса: $PURGE_KEYCHAIN_SERVICE"
    say "  НЕ затрагивается: TCC (Accessibility/Notifications), keychain других приложений."

    if [ "$ASSUME_YES" != "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            would "запрос подтверждения purge (пропущен в dry-run)"
        else
            printf '  Введите YES для подтверждения полного удаления: '
            local resp; read -r resp || true
            if [ "$resp" != "YES" ]; then
                say "  Purge отменён пользователем. Пользовательские данные сохранены."
                note_kept "пользовательские данные (purge отменён)"
                return 0
            fi
        fi
    fi

    rm_file "$USER_PREFS/com.trykelvin.kelvin.plist" || true
    note_purge "$USER_PREFS/com.trykelvin.kelvin.plist"
    # defaults тоже сбрасываем, чтобы не осталось в кэше cfprefsd
    if [ "$LIVE_LAUNCHCTL" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then would "defaults delete com.trykelvin.kelvin"; else
            defaults delete com.trykelvin.kelvin 2>/dev/null || true
        fi
    fi
    rm_dir "$USER_APP_SUPPORT/Kelvin" || true
    note_purge "$USER_APP_SUPPORT/Kelvin"

    # keychain: удаляем только конкретную запись по имени сервиса (мягко). TCC не трогаем.
    if [ "$LIVE_LAUNCHCTL" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            would "security delete-generic-password -s $PURGE_KEYCHAIN_SERVICE"
        else
            security delete-generic-password -s "$PURGE_KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
            note_purge "keychain: $PURGE_KEYCHAIN_SERVICE (если была)"
        fi
    fi
}

# ═════════════════════════ отчёт ═════════════════════════
print_report() {
    say ""
    say "═══ Отчёт ═══"
    if [ "$DRY_RUN" = "1" ]; then say "РЕЖИМ: dry-run (ничего не изменено)"; fi

    if [ ${#REPORT_REMOVED[@]} -gt 0 ]; then
        say "Удалено:"; printf '  • %s\n' "${REPORT_REMOVED[@]}"
    fi
    if [ ${#REPORT_PURGE[@]} -gt 0 ]; then
        say "Удалено (purge):"; printf '  • %s\n' "${REPORT_PURGE[@]}"
    fi
    if [ ${#REPORT_MISSING[@]} -gt 0 ]; then
        say "Не найдено (уже отсутствовало): ${#REPORT_MISSING[@]} объект(ов)"
    fi
    if [ ${#REPORT_KEPT[@]} -gt 0 ]; then
        say "Сохранено:"; printf '  • %s\n' "${REPORT_KEPT[@]}"
    fi
    if [ ${#REPORT_ERRORS[@]} -gt 0 ]; then
        say "Ошибки:"; printf '  • %s\n' "${REPORT_ERRORS[@]}"
    fi

    # рекомендация по privileged/SMAppService
    if [ "$DRY_RUN" = "0" ] && [ "$LIVE_LAUNCHCTL" = "1" ]; then
        say ""
        say "Примечание: привилегированный GPU-демон (com.trykelvin.kelvin.privileged)"
        say "регистрируется через SMAppService. Из shell выполнен launchctl bootout —"
        say "служба остановлена и не будет respawn по удалённому bundle. Для финальной"
        say "очистки записи SMAppService рекомендуется перезагрузка (macOS уберёт"
        say " orphan-регистрацию сама) — либо переустановите и выключите службу в приложении."
    fi

    if [ ${#REPORT_ERRORS[@]} -gt 0 ]; then
        say ""
        say "✗ Очистка завершена с ошибками (см. выше)."
        exit 1
    fi
    say ""
    say "✓ Очистка завершена."
}

# ───────────────────────── запуск ─────────────────────────
if [ "$(id -u)" = "0" ] && [ "$LIVE_LAUNCHCTL" = "1" ] && [ "$DRY_RUN" = "0" ]; then
    say "⚠ Скрипт запущен под root целиком — это не требуется (права запрашиваются точечно). Продолжаю."
fi

phase_user
phase_system
phase_purge
print_report
