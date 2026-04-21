#!/usr/bin/env bash
if [ -n "${DEBUG_SCRIPT:-}" ]; then
  set -x
fi
set -eu -o pipefail
cd $APP_ROOT

LOG_FILE="logs/init-$(date +%F-%T).log"
exec > >(tee $LOG_FILE) 2>&1

TIMEFORMAT=%lR
# For faster performance, don't audit dependencies automatically.
export COMPOSER_NO_AUDIT=1
# For faster performance, don't install dev dependencies.
export COMPOSER_NO_DEV=1

#== Remove root-owned files.
echo
echo Remove root-owned files.
time sudo rm -rf lost+found

#== Composer install.
echo
if [ -f composer.json ]; then
  if composer show --locked cweagans/composer-patches ^2 &> /dev/null; then
    echo 'Update patches.lock.json.'
    time composer prl
    echo
  fi
else
  echo 'Generate composer.json.'
  time source .devpanel/composer_setup.sh
  echo
fi
# If update fails, change it to install.
time composer -n update --no-dev --no-progress

#== Create the private files directory.
if [ ! -d private ]; then
  echo
  echo 'Create the private files directory.'
  time mkdir private
fi

#== Create the config sync directory.
if [ ! -d config/sync ]; then
  echo
  echo 'Create the config sync directory.'
  time mkdir -p config/sync
fi

#== Install Drupal.
echo
if [ -z "$(drush status --field=db-status)" ]; then
  echo 'Install Drupal.'
  time drush -n si
else
  echo 'Update database.'
  time drush -n updb
fi

# ==============================================================================
# SET UP ALERT BAR (DYNAMIC DATA FETCHING & INJECTION)
# ==============================================================================
echo
echo 'Configuring DevPanel Alert Bar...'

# 1. Fetch Dynamic Data from DrupalForge Proxy
CURRENT_APP_ID="${DP_APP_ID:-}"
if [ -z "$CURRENT_APP_ID" ]; then
    echo "⚠️ Không tìm thấy DP_APP_ID. Dùng dữ liệu mặc định."
    export RAW_API_JSON=""
    export BASE_PLATFORM_URL=""
    export BUY_LINK_URL="https://www.devpanel.com/pricing/"
else
    # Tự động nhận diện môi trường từ Hostname
    if [ -n "${DP_HOSTNAME:-}" ]; then
        CURRENT_ENV=$(echo "$DP_HOSTNAME" | cut -d'-' -f1)
    else
        CURRENT_ENV="dev"
    fi

    case "$CURRENT_ENV" in
        "local" | "docksal") BASE_PROXY_URL="https://drupal-forge.docksal.site:8444" ;;
        "dev") BASE_PROXY_URL="https://dev.drupalforge.org" ;;
        "stage" | "staging") BASE_PROXY_URL="https://stage.drupalforge.org" ;;
        "prod" | "production" | "www") BASE_PROXY_URL="https://www.drupalforge.org" ;;
        *) BASE_PROXY_URL="https://dev.drupalforge.org" ;;
    esac

    DRUPALFORGE_PROXY="${BASE_PROXY_URL}/api/internal/alert-app-info?app_id=${CURRENT_APP_ID}"
    
    # Lấy dữ liệu JSON từ API (export để đẩy sang cho PHP xử lý)
    export BASE_PLATFORM_URL="${BASE_PROXY_URL}/app/purchase/"
    export RAW_API_JSON=$(curl -s -f -X GET "$DRUPALFORGE_PROXY" || true)
    export BUY_LINK_URL="${BASE_PROXY_URL}/app/purchase/${CURRENT_APP_ID}"
fi

# 2. Dùng PHP CLI để xử lý Data và sinh ra file alert-bar-data.json an toàn
php -r '
    // Đọc biến môi trường do Bash truyền vào
    $raw_json = getenv("RAW_API_JSON");
    $buy_link = getenv("BASE_PLATFORM_URL");
    
    // Parse JSON từ API (nếu API lỗi, sẽ trả về mảng rỗng)
    $api_data = json_decode($raw_json, true) ?:[];
    
    // Chuẩn bị dữ liệu an toàn
    $submissionId = $api_data["submissionId"] ?? "submissionId";
    $templateId = $api_data["templateId"] ?? "templateId";

    $safe_data = [
        "appName" => $api_data["appName"] ?? "My Application",
        "subId" => $submissionId,
        "email" => $api_data["email"] ?? "",
        "buyLink" => $buy_link . $submissionId . "/" . $templateId,
    ];
    
    // Ghi ra file JSON chuẩn mực (chống lỗi syntax mọi ký tự đặc biệt)
    $json_output = json_encode($safe_data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    file_put_contents("alert-bar-data.json", $json_output);
'

echo "✅ Ghi dữ liệu JSON (alert-bar-data.json) bằng PHP thành công!"

# 3. Tiêm code nhúng alert-bar.php vào index.php
if [ -f "web/index.php" ]; then
  # Kiểm tra xem file index.php đã có chuỗi alert-bar.php chưa để tránh chèn đè 2 lần 
  # (phòng trường hợp người dùng chạy init.sh nhiều lần)
  if ! grep -q "alert-bar.php" web/index.php; then
    sed -i 's/<?php/<?php\ninclude_once __DIR__ . "\/..\/.devpanel\/alert-bar.php";\n/g' web/index.php
    echo "✅ Đã gắn thanh Alert Bar vào index.php thành công!"
  else
    echo "✅ Thanh Alert Bar đã được nhúng từ trước."
  fi
fi
# ==============================================================================

#== Warm up caches.
echo
echo 'Run cron.'
time drush cron
echo
echo 'Populate caches.'
time drush cache:warm &> /dev/null || :
time .devpanel/warm

#== Finish measuring script time.
INIT_DURATION=$SECONDS
INIT_HOURS=$(($INIT_DURATION / 3600))
INIT_MINUTES=$(($INIT_DURATION % 3600 / 60))
INIT_SECONDS=$(($INIT_DURATION % 60))
printf "\nTotal elapsed time: %d:%02d:%02d\n" $INIT_HOURS $INIT_MINUTES $INIT_SECONDS
