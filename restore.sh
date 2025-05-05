#!/bin/bash

export PGDATA=$HOME/evh98 
export ENC=ISO8859-15 
export LOC=en_US.ISO8859-15
BACKUP_DIR="$HOME/backups"
DB_DIR="$HOME/evh98"
CONFIG_DIR="$HOME/configs"
TEMP_DIR="$HOME/backups/tmp.sql"
tablespaces=(
    ["tablespace1"]="$HOME/fnd85"
)
latest_backup=$(ls -t ${BACKUP_DIR}/backup_all_* | head -n 1)
# Находим самый поздний backup
if [ ! -f "${latest_backup}" ]; then 
    echo "No backup files found" 
    exit 1
fi
echo "Using ${latest_backup}"
# Останавливаем сервер
pg_ctl -D ${DB_DIR} stop
# Пересоздаем директории кластера 
rm -rf ${DB_DIR}
mkdir ${DB_DIR}
for ts in "${!tablespaces[@]}"; do 
    dir="${tablespaces[$ts]}"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
    else 
        rm -rf "$dir"
        mkdir -p "$dir"
    fi
done
ls -la $PGDATA
initdb -D $PGDATA --encoding=$ENC --locale=$LOC
cp ${CONFIG_DIR}/postgresql.conf ${DB_DIR}/postgresql.conf
cp ${CONFIG_DIR}/pg_hba.conf ${DB_DIR}/pg_hba.conf
gunzip -c "${latest_backup}" > "$TEMP_DIR"
pg_ctl -D ${DB_DIR} start
# Восстанавливаем данные из дампа 
psql -d postgres -p 9792 -f $TEMP_DIR
rm -rf "$TEMP_DIR"
echo "Complete"