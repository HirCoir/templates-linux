#!/bin/bash
#
# Script: autofs-manager.sh
# Creado por: HirCoir (youtube.com/@hircoir)
# Description: Instala y configura Autofs en sistemas Debian/Ubuntu, y proporciona un menú
#              para montar/desmontar particiones automáticamente usando UUID.
#              El punto de montaje base es /montajes/autofs.
#
# Uso:
#   1) Guardar este script como /usr/local/bin/autofs-manager.sh
#   2) Dar permisos de ejecución: sudo chmod +x /usr/local/bin/autofs-manager.sh
#   3) Ejecutar como root: sudo /usr/local/bin/autofs-manager.sh
#
# Este script:
#   – Instala autofs si no está instalado.
#   – Añade (si no existe) la línea correspondiente en /etc/auto.master para usar /etc/auto.userdisks.
#   – Crea /etc/auto.userdisks como archivo de mapas de Autofs.
#   – Provee un menú interactivo para:
#       1) Listar particiones disponibles (no montadas) e instalar una entrada en Autofs.
#       2) Eliminar una entrada de /etc/auto.userdisks y desmontar la partición.
#       3) Mostrar montajes actuales gestionados por Autofs.
#       4) Salir.
#
# NOTA: Debe ejecutarse como usuario root. Se recomienda revisar las copias de seguridad creadas
#       de /etc/auto.master y /etc/auto.userdisks antes de modificar manualmente.

set -e

# Punto de montaje base
BASE_MOUNT_DIR="/montajes/autofs"
# Archivo de mapas personalizado
MAP_FILE="/etc/auto.userdisks"
# Archivo maestro de Autofs
MASTER_FILE="/etc/auto.master"
MASTER_ENTRY="${BASE_MOUNT_DIR}    ${MAP_FILE}    --timeout=60    --ghost"

# Función: Verificar ejecución como root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Este script debe ejecutarse como root. Usa sudo."
        exit 1
    fi
}

# Función: Instalar Autofs si no está presente
install_autofs() {
    if ! dpkg -s autofs &> /dev/null; then
        echo "Instalando autofs..."
        apt update
        apt install -y autofs
    else
        echo "Autofs ya está instalado."
    fi

    # Habilitar e iniciar el servicio
    systemctl enable autofs
    systemctl start autofs
}

# Función: Asegurar que /etc/auto.master tenga únicamente la entrada para nuestro MAP_FILE
ensure_master_entry() {
    # Crear directorio base de montaje si no existe
    if [[ ! -d "$BASE_MOUNT_DIR" ]]; then
        mkdir -p "$BASE_MOUNT_DIR"
        echo "Directorio base de montaje creado: ${BASE_MOUNT_DIR}"
    fi

    # Comentar cualquier línea en /etc/auto.master que use "/media/" como punto de montaje
    if grep -E '^[[:space:]]*/media/' "$MASTER_FILE" &> /dev/null; then
        echo "Comentando líneas que apuntan a /media/ en ${MASTER_FILE} para evitar conflictos..."
        cp "$MASTER_FILE" "${MASTER_FILE}.bak_before_media_comment"
        sed -i -r 's@^([[:space:]]*/media/.*)@# \1@' "$MASTER_FILE"
    fi

    # Verificar si ya existe entrada exacta para nuestro MAP_FILE
    if ! grep -Fq "$MAP_FILE" "$MASTER_FILE"; then
        echo "Creando respaldo de ${MASTER_FILE} en ${MASTER_FILE}.bak"
        cp "$MASTER_FILE" "${MASTER_FILE}.bak"
        echo "" >> "$MASTER_FILE"
        echo "# Entrada añadida por autofs-manager.sh" >> "$MASTER_FILE"
        echo "$MASTER_ENTRY" >> "$MASTER_FILE"
        echo "Entrada añadida a ${MASTER_FILE}:"
        echo "  $MASTER_ENTRY"
        echo "Reiniciando autofs para aplicar cambios..."
        systemctl restart autofs
    else
        echo "La entrada para ${MAP_FILE} ya existe en ${MASTER_FILE}."
    fi
}

# Función: Asegurar que el archivo de mapas exista
ensure_map_file() {
    if [[ ! -f "$MAP_FILE" ]]; then
        echo "Creando respaldo (vacío) de ${MAP_FILE} en ${MAP_FILE}.bak"
        touch "$MAP_FILE"
        cp "$MAP_FILE" "${MAP_FILE}.bak"
        echo "# Archivo de mapas para autofs creado por autofs-manager.sh" > "$MAP_FILE"
    fi
}

# Función: Listar particiones disponibles (no montadas), mostrando nombre, uuid, tipo, tamaño, etiqueta
list_available_partitions() {
    echo "Buscando particiones disponibles (no montadas)..."
    # Filtrar particiones (TYPE=part) que no estén montadas (MOUNTPOINT="")
    mapfile -t PARTS < <(lsblk -fp -o NAME,UUID,FSTYPE,SIZE,LABEL,MOUNTPOINT | awk '$6=="" && $3!="" { print }')

    if [[ ${#PARTS[@]} -eq 0 ]]; then
        echo "No se encontraron particiones libres para montar."
        return 1
    fi

    echo "Particiones disponibles:"
    printf "%-3s | %-20s | %-36s | %-7s | %-8s | %-15s\n" "No." "DISPOSITIVO" "UUID" "FSTYPE" "SIZE" "LABEL"
    echo "----+----------------------+--------------------------------------+---------+----------+-----------------"
    for i in "${!PARTS[@]}"; do
        IFS=' ' read -r DEV UUID FSTYPE SIZE LABEL MPT <<< "${PARTS[i]}"
        [[ -z "$LABEL" ]] && LABEL="-"
        printf "%-3d | %-20s | %-36s | %-7s | %-8s | %-15s\n" "$((i+1))" "$DEV" "$UUID" "$FSTYPE" "$SIZE" "$LABEL"
    done

    return 0
}

# Función: Añadir una partición a autofs
add_partition() {
    if ! list_available_partitions; then
        echo "Nada que agregar."
        return
    fi

    read -rp "Ingresa el número de la partición que deseas montar: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#PARTS[@]} )); then
        echo "Selección inválida."
        return
    fi

    # Obtener datos de la partición seleccionada
    IFS=' ' read -r DEV UUID FSTYPE SIZE LABEL MPT <<< "${PARTS[$((choice-1))]}"
    # Nombre sugerido para el subdirectorio (por defecto, nombre de dispositivo sin '/dev/')
    DEFAULT_NAME="$(basename "$DEV")"
    read -erp "Nombre para el punto de montaje [${DEFAULT_NAME}]: " mount_name
    [[ -z "$mount_name" ]] && mount_name="$DEFAULT_NAME"

    # Nuevo punto de montaje bajo /montajes/autofs
    mount_point="${BASE_MOUNT_DIR}/${mount_name}"
    if [[ ! -d "$mount_point" ]]; then
        mkdir -p "$mount_point"
        echo "Directorio de montaje creado: $mount_point"
    else
        echo "El directorio $mount_point ya existe (quizá de un intento previo)."
    fi

    # Si no detecta fstype, usar 'auto'
    [[ -z "$FSTYPE" ]] && FSTYPE="auto"

    # Agregar la línea a /etc/auto.userdisks
    echo "${mount_name}    -fstype=${FSTYPE}    :UUID=${UUID}" >> "$MAP_FILE"
    echo ""
    echo "#### Nueva entrada añadida a ${MAP_FILE}:"
    echo "    ${mount_name}    -fstype=${FSTYPE}    :UUID=${UUID}"
    echo "#### Detalles de la partición:"
    echo "  • Dispositivo:      ${DEV}"
    echo "  • UUID:             ${UUID}"
    echo "  • Tipo de FS:       ${FSTYPE}"
    echo "  • Tamaño:           ${SIZE}"
    echo "  • Etiqueta (LABEL): ${LABEL:--}"
    echo "  • Punto de montaje: ${mount_point}"
    echo ""

    # Reiniciar autofs para aplicar cambios
    systemctl restart autofs
    echo "Autofs reiniciado. En cuanto accedas a '${mount_point}', se montará la partición."
}

# Función: Listar y eliminar una entrada existente de autofs
remove_partition() {
    if [[ ! -s "$MAP_FILE" ]]; then
        echo "No hay particiones configuradas en ${MAP_FILE}."
        return
    fi

    echo "Entradas actuales en ${MAP_FILE}:"
    mapfile -t ENTRIES < <(grep -E -v '^\s*#' "$MAP_FILE" | sed '/^\s*$/d')
    if [[ ${#ENTRIES[@]} -eq 0 ]]; then
        echo "No hay entradas activas en ${MAP_FILE}."
        return
    fi

    printf "%-3s | %-20s | %-30s\n" "No." "NAME" "PUNTO DE MONTAJE"
    echo "----+----------------------+--------------------------------"
    for i in "${!ENTRIES[@]}"; do
        name=$(echo "${ENTRIES[i]}" | awk '{print $1}')
        mount_point="${BASE_MOUNT_DIR}/${name}"
        printf "%-3d | %-20s | %-30s\n" "$((i+1))" "$name" "$mount_point"
    done

    read -rp "Ingresa el número de la entrada que deseas eliminar: " rem_choice
    if ! [[ "$rem_choice" =~ ^[0-9]+$ ]] || (( rem_choice < 1 || rem_choice > ${#ENTRIES[@]} )); then
        echo "Selección inválida."
        return
    fi

    sel_line="${ENTRIES[$((rem_choice-1))]}"
    sel_name=$(echo "$sel_line" | awk '{print $1}')
    mount_point="${BASE_MOUNT_DIR}/${sel_name}"

    # Respaldar antes de eliminar
    cp "$MAP_FILE" "${MAP_FILE}.bak"

    # Eliminar la línea exacta del mapa
    grep -Fvx "$sel_line" "$MAP_FILE" > "${MAP_FILE}.tmp" && mv "${MAP_FILE}.tmp" "$MAP_FILE"
    echo ""
    echo "#### Entrada eliminada de ${MAP_FILE}:"
    echo "    $sel_line"
    echo "#### Punto de montaje eliminado de Autofs: ${mount_point}"
    echo ""

    # Si está montado, desmontar
    if [[ -d "$mount_point" ]]; then
        if mountpoint -q "$mount_point"; then
            umount "$mount_point" || true
            echo "  • Partición desmontada de ${mount_point}"
        else
            echo "  • El directorio ${mount_point} no estaba montado."
        fi

        # Preguntar si desea borrar el directorio vacío
        read -rp "¿Deseas eliminar el directorio vacío ${mount_point}? [s/N]: " del_dir
        if [[ "${del_dir,,}" == "s" ]]; then
            rmdir "$mount_point" && echo "  • Directorio ${mount_point} eliminado."
        else
            echo "  • Se conserva el directorio ${mount_point} (puedes borrarlo manualmente si quieres)."
        fi
    fi

    # Reiniciar autofs para aplicar cambios
    systemctl restart autofs
    echo "Autofs reiniciado."
}

# Función: Mostrar estado de montajes actuales (solo los gestionados por nuestro mapa)
show_current_mounts() {
    if [[ ! -s "$MAP_FILE" ]]; then
        echo "No hay entradas en ${MAP_FILE}."
        return
    fi

    echo "Verificando montajes actuales (gestión Autofs → base ${BASE_MOUNT_DIR}):"
    while read -r line; do
        [[ "$line" =~ ^\s*# ]] && continue
        [[ -z "$line" ]] && continue
        name=$(echo "$line" | awk '{print $1}')
        mount_point="${BASE_MOUNT_DIR}/${name}"
        if mountpoint -q "$mount_point"; then
            dev=$(mount | grep "on ${mount_point} " | awk '{print $1}')
            echo "  • '${name}' → montado en '${mount_point}' (dispositivo: ${dev})"
        else
            echo "  • '${name}' → no montado (entra a '${mount_point}' para que Autofs lo monte)"
        fi
    done < <(grep -E -v '^\s*#' "$MAP_FILE")
}

# Función: Menú principal
main_menu() {
    while true; do
        echo ""
        echo "====== Gestor de particiones con Autofs ======"
        echo "1) Listar particiones disponibles e instalar entrada en Autofs"
        echo "2) Eliminar entrada de Autofs"
        echo "3) Mostrar estado de montajes actuales"
        echo "4) Salir"
        echo "=============================================="
        read -rp "Selecciona una opción [1-4]: " opt
        case "$opt" in
            1) add_partition ;;
            2) remove_partition ;;
            3) show_current_mounts ;;
            4) echo "Saliendo..."; exit 0 ;;
            *) echo "Opción inválida. Intenta de nuevo." ;;
        esac
    done
}

# -----------------------
# Ejecución principal
# -----------------------
check_root
install_autofs
ensure_master_entry
ensure_map_file
main_menu
