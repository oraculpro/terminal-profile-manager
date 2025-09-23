#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_EXPORT_NAME="gnome-terminal-profile-$(date +%Y%m%d-%H%M%S).dconf"

# Цвета для красоты
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Проверка зависимостей
check_dependencies() {
    if ! command -v dconf &> /dev/null; then
        error "dconf не установлен. Установите: sudo apt install dconf-cli"
        exit 1
    fi
    if ! command -v gsettings &> /dev/null; then
        error "gsettings не найден (обычно входит в gnome)."
        exit 1
    fi
}

# Получить список профилей: UUID -> имя
get_profiles() {
    local list=$(gsettings get org.gnome.Terminal.ProfilesList list 2>/dev/null)
    # Убираем начальные [ и конечные ]
    list=$(echo "$list" | sed "s/^\[\s*//; s/\s*\]$//; s/', '/\n/g; s/'//g")
    if [ -z "$list" ]; then
        echo ""
        return
    fi
    echo "$list"
}

# Получить имя профиля по UUID
get_profile_name() {
    local uuid="$1"
    gsettings get org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$uuid/ visible-name 2>/dev/null | sed "s/^'//; s/'$//"
}

# Получить UUID активного (default) профиля
get_default_profile_uuid() {
    gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | sed "s/'//g"
}

# Экспорт профиля
export_profile() {
    local uuid="$1"
    local output_file="$2"

    if [ -z "$uuid" ]; then
        error "UUID профиля не указан"
        return 1
    fi

    if [ -z "$output_file" ]; then
        output_file="$DEFAULT_EXPORT_NAME"
    fi

    # Проверяем, существует ли профиль
    local name=$(get_profile_name "$uuid")
    if [ -z "$name" ]; then
        error "Профиль с UUID $uuid не найден"
        return 1
    fi

    log "Экспортирую профиль: $name ($uuid)"
    dconf dump "/org/gnome/terminal/legacy/profiles:/:$uuid/" > "$output_file"

    if [ $? -eq 0 ]; then
        log "Успешно экспортировано в: $output_file"
        echo "UUID=$uuid" >> "$output_file"
        echo "VISIBLE_NAME=$name" >> "$output_file"
        log "Метаданные (UUID и имя) добавлены в конец файла."
    else
        error "Ошибка при экспорте"
        return 1
    fi
}

# Импорт профиля
import_profile() {
    local input_file="$1"

    if [ ! -f "$input_file" ]; then
        error "Файл $input_file не найден"
        return 1
    fi

    # Читаем метаданные из конца файла
    local saved_uuid=$(grep "^UUID=" "$input_file" | cut -d= -f2)
    local saved_name=$(grep "^VISIBLE_NAME=" "$input_file" | cut -d= -f2)

    # Создаём новый профиль
    log "Создаём новый профиль..."
    # Временное имя
    local temp_name="Imported-$(date +%H%M%S)"
    local new_uuid=$(uuidgen)

    # Добавляем UUID в список профилей
    local current_list=$(gsettings get org.gnome.Terminal.ProfilesList list)
    # Убираем [ и ]
    current_list=$(echo "$current_list" | sed "s/^\[\s*//; s/\s*\]$//")
    if [ -z "$current_list" ]; then
        new_list="['$new_uuid']"
    else
        new_list="[$current_list, '$new_uuid']"
    fi
    gsettings set org.gnome.Terminal.ProfilesList list "$new_list"

    # Загружаем настройки
    log "Загружаем настройки в новый профиль: $new_uuid"
    head -n -2 "$input_file" | dconf load "/org/gnome/terminal/legacy/profiles:/:$new_uuid/"

    if [ $? -ne 0 ]; then
        error "Ошибка при загрузке настроек"
        return 1
    fi

    # Устанавливаем имя (если было сохранено)
    if [ -n "$saved_name" ]; then
        gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$new_uuid/ visible-name "$saved_name"
        log "Имя профиля установлено: $saved_name"
    else
        gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$new_uuid/ visible-name "$temp_name"
        warn "Имя не найдено, установлено: $temp_name"
    fi

    # Спрашиваем, сделать ли его профилем по умолчанию
    read -p "Сделать этот профиль профилем по умолчанию? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        gsettings set org.gnome.Terminal.ProfilesList default "$new_uuid"
        log "Профиль $new_uuid установлен как профиль по умолчанию"
    fi

    log "✅ Импорт завершён. Новый UUID: $new_uuid"
}

# Интерактивный выбор профиля для экспорта
choose_profile_interactive() {
    local profiles=$(get_profiles)
    if [ -z "$profiles" ]; then
        error "Нет доступных профилей"
        return 1
    fi

    local i=1
    declare -A uuid_map
    echo -e "${BLUE}Доступные профили:${NC}"
    while IFS= read -r uuid; do
        if [ -n "$uuid" ]; then
            name=$(get_profile_name "$uuid")
            echo "  $i) $name ($uuid)"
            uuid_map[$i]="$uuid"
            ((i++))
        fi
    done <<< "$profiles"

    read -p "Выберите номер профиля для экспорта: " choice
    if [[ -z "${uuid_map[$choice]}" ]]; then
        error "Неверный выбор"
        return 1
    fi

    echo "${uuid_map[$choice]}"
}

# Главное меню
show_menu() {
    clear
    echo -e "${GREEN}=== Менеджер профилей GNOME Terminal ===${NC}"
    echo "1) Экспортировать профиль (интерактивно)"
    echo "2) Экспортировать текущий (default) профиль"
    echo "3) Импортировать профиль из файла"
    echo "4) Выход"
    echo
    read -p "Выберите действие (1-4): " action

    case $action in
        1)
            uuid=$(choose_profile_interactive)
            if [ $? -eq 0 ] && [ -n "$uuid" ]; then
                read -p "Имя файла для сохранения (Enter для $DEFAULT_EXPORT_NAME): " filename
                filename=${filename:-$DEFAULT_EXPORT_NAME}
                export_profile "$uuid" "$filename"
            fi
            ;;
        2)
            uuid=$(get_default_profile_uuid)
            if [ -z "$uuid" ]; then
                error "Не удалось определить профиль по умолчанию"
                return
            fi
            name=$(get_profile_name "$uuid")
            log "Текущий профиль: $name ($uuid)"
            read -p "Имя файла для сохранения (Enter для $DEFAULT_EXPORT_NAME): " filename
            filename=${filename:-$DEFAULT_EXPORT_NAME}
            export_profile "$uuid" "$filename"
            ;;
        3)
            echo "Поддерживаемые файлы: *.dconf"
            # Список файлов .dconf в текущей директории
            files=(*.dconf)
            if [ ${#files[@]} -eq 1 ] && [ ! -f "${files[0]}" ]; then
                echo "Нет .dconf файлов в текущей папке."
                read -p "Введите полный путь к файлу: " filepath
            else
                echo "Файлы в текущей директории:"
                select fname in "${files[@]}" "Ввести путь вручную" "Отмена"; do
                    case $fname in
                        "Ввести путь вручную")
                            read -p "Введите путь: " filepath
                            break
                            ;;
                        "Отмена")
                            return
                            ;;
                        *)
                            filepath="$fname"
                            break
                            ;;
                    esac
                done
            fi

            if [ -n "$filepath" ] && [ -f "$filepath" ]; then
                import_profile "$filepath"
            else
                error "Файл не выбран или не существует"
            fi
            ;;
        4)
            echo "Выход."
            exit 0
            ;;
        *)
            error "Неверный выбор"
            ;;
    esac

    echo
    read -p "Нажмите Enter для возврата в меню..."
}

# Основная логика
main() {
    check_dependencies

    # Если переданы аргументы — работаем в режиме CLI
    if [ $# -gt 0 ]; then
        case $1 in
            export|EXPORT)
                if [ $# -eq 1 ]; then
                    # Экспорт default профиля
                    uuid=$(get_default_profile_uuid)
                    if [ -z "$uuid" ]; then
                        error "Не удалось получить профиль по умолчанию"
                        exit 1
                    fi
                    export_profile "$uuid" "$DEFAULT_EXPORT_NAME"
                elif [ $# -eq 2 ]; then
                    # Экспорт указанного профиля в указанный файл
                    export_profile "$1" "$2"
                else
                    error "Использование: $0 export [UUID] [файл.dconf]"
                    exit 1
                fi
                ;;
            import|IMPORT)
                if [ $# -ne 2 ]; then
                    error "Использование: $0 import /путь/к/файлу.dconf"
                    exit 1
                fi
                import_profile "$2"
                ;;
            *)
                error "Неизвестная команда: $1"
                echo "Доступные команды: export, import"
                exit 1
                ;;
        esac
    else
        # Интерактивный режим
        while true; do
            show_menu
        done
    fi
}

main "$@"
