#!/bin/bash

# ==========================================
#  RTSPカメラ録画スクリプト (Mac用)
# ==========================================

# --- カメラ設定エリア -----------------------

# 設定ファイル読み込み
CONFIG_FILE="./recorder.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=./recorder.conf
    source "$CONFIG_FILE"
else
    echo "エラー: 設定ファイル ${CONFIG_FILE} が見つかりません。"
    echo "recorder.conf.template をコピーして作成してください。"
    exit 1
fi

# ------------------------------------------

# 1. タイムスタンプ取得 (YYYYMMDD_HHMMSS形式)
START_TIME=$(date +"%Y%m%d_%H%M%S")

# 2. 保存用ディレクトリ作成
# 設定ファイルで SAVE_DIR_ROOT が指定されていればそれを使用
if [ -n "$SAVE_DIR_ROOT" ]; then
    # 末尾の / を削除して正規化
    BASE_DIR="${SAVE_DIR_ROOT%/}"
else
    # 指定がなければカレントディレクトリ
    BASE_DIR="."
fi

OUT_DIR="${BASE_DIR}/${START_TIME}"

echo "保存先ディレクトリを作成中: ${OUT_DIR}"
mkdir -p "$OUT_DIR"

if [ ! -d "$OUT_DIR" ]; then
    echo "エラー: 保存先ディレクトリを作成できませんでした: $OUT_DIR"
    echo "書き込み権限やパスを確認してください。"
    exit 1
fi

echo "================================================="
echo " 録画を開始します"
echo " 開始時刻: ${START_TIME}"
echo " 保存場所: ${OUT_DIR}/"
echo " -----------------------------------------------"
echo " [停止方法] ターミナルで 'Ctrl + C' を押してください"
echo "================================================="

# Ctrl+C が押されたら、バックグラウンドのプロセス(ffmpeg/ffplay)を全て終了する設定
cleanup() {
    echo "録画を停止しています..."
    # FIFOファイルを削除（/tmp に作成されている）
    rm -f /tmp/${START_TIME}_*_preview.fifo 2>/dev/null
    kill 0
}
trap cleanup SIGINT

# --- 録画・プレビュー実行関数 ---
start_recording() {
    local URL=$1
    local NAME=$2
    # .mp4 は強制終了時にファイルが壊れやすいため、.mkv (Matroska) を使用
    local FILE_NAME="${START_TIME}_${NAME}.mkv"
    local FILE_PATH="${OUT_DIR}/${FILE_NAME}"
    # FIFOは /tmp に作成（USBドライブなどFIFO非対応のファイルシステム対策）
    local FIFO_PATH="/tmp/${START_TIME}_${NAME}_preview.fifo"

    # 名前付きパイプを作成（プレビュー用）
    mkfifo "$FIFO_PATH"

    # ffplayをバックグラウンドで起動（FIFOから読み取り）
    # FIFOからの読み取りが失敗しても録画に影響しない
    ffplay -window_title "Live: ${NAME}" -x 640 -y 360 -i "$FIFO_PATH" >/dev/null 2>&1 &

    # FFmpegコマンド解説
    # -rtsp_transport tcp : 映像乱れ防止
    # -i ...              : 入力
    # -an                 : 音声カット
    # -c:v copy           : ストリームコピー(CPU負荷低)
    # -f tee              : 保存とプレビューに分岐
    # ファイルを先に指定することで、確実にmuxerを初期化

    ffmpeg \
        -rtsp_transport tcp \
        -fflags +genpts \
        -i "$URL" \
        -an \
        -map 0:v \
        -c:v copy \
        -f tee "[f=matroska]${FILE_PATH}|[f=nut:onfail=ignore]${FIFO_PATH}" \
        2> "${OUT_DIR}/${NAME}.log" &

    echo " > Rec開始: ${FILE_NAME}"
}

# カメラ実行ループ (最大4台)
HAS_CAMERA=0

for i in {1..4}; do
    # 変数名を動的に生成 (例: CAM1_URL, CAM1_NAME)
    URL_VAR="CAM${i}_URL"
    NAME_VAR="CAM${i}_NAME"

    # 間接参照で値を取得
    URL="${!URL_VAR}"
    NAME="${!NAME_VAR}"

    # URLが設定されている場合のみ実行
    if [ -n "$URL" ]; then
        # 名前が未設定の場合はデフォルト名を使用
        if [ -z "$NAME" ]; then
            NAME="cam${i}"
        fi

        start_recording "$URL" "$NAME"
        HAS_CAMERA=1
    fi
done

if [ "$HAS_CAMERA" -eq 0 ]; then
    echo "エラー: 有効なカメラ設定(CAMx_URL)が見つかりません。"
    echo "recorder.conf を確認してください。"
    exit 1
fi

# プロセス終了まで待機
wait
