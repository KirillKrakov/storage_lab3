#!/bin/sh
CURRENT_DATE=$(date "+%Y-%m-%d_%H:%M:%S")
BACKUP_DIR="backups"
ARCHIVE_NAME="backup_all_${CURRENT_DATE}.tar.gz"
REMOTE_HOST="postgres2@pg111"
# Создаем полную резервную копию, размещенную на резервном узле в виде архива
ssh ${REMOTE_HOST} "mkdir ${BACKUP_DIR}"
pg_dumpall -p 9792 |  gzip | ssh ${REMOTE_HOST} "cat > ${BACKUP_DIR}/${ARCHIVE_NAME}"
# Удаляем резервные копии старше 28 дней на резервном узле
ssh ${REMOTE_HOST} 'find backups/ -type d -mtime +28 -exec rm -rf {} \;'