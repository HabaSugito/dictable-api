# Hark Server

**macOS 標準のオンデバイス音声認識を、ローカル API として使えるようにするメニューバーアプリです。**
OpenAI 互換の HTTP API でのファイル文字起こしと、WebSocket での逐次文字起こしに対応しています。無料・オフラインで動き、音声は Mac の外に出ません。

**Web サイト:** https://hark-server.living-with-tree.workers.dev · [English README](README.md)

## 特長

- **OpenAI の文字起こし API と互換**: `base_url` を変えるだけで、既存のコードがそのまま動きます。
- **リアルタイム字幕**: 話している途中から文字が出て（約 1 秒遅れ）、文が終わるとすぐ確定します。
- **モデル管理も GPU も API 料金も不要**: 言語ごとの認識モデルは、初めて使うときに macOS が自動でダウンロードします。
- **外部ライブラリなし**: HTTP/1.1 と WebSocket（RFC 6455）を `Network.framework` の上に直接実装しています。

MacBook Air（M シリーズ、メモリ 16GB）で 24 秒の英語音声を試すと、ファイル全体の文字起こしは約 1.4 秒でした。ストリーミングでは、話し始めて約 1 秒で最初の文字が出て、文が終わってから約 0.2 秒で確定します。

## 動作環境

- macOS 26（Tahoe）以降、Apple シリコン
- ソースからビルドする場合は Xcode 26

## インストール

[Releases](../../releases) から `HarkServer-x.y.z.zip` をダウンロードして展開し、**Hark Server.app** をアプリケーションフォルダに移します。
Apple の公証を受けていないため、初回の起動は macOS に止められます。**システム設定 → プライバシーとセキュリティ** で **このまま開く** を一度押してください。ソースから自分でビルドした場合は止められません。

ソースからビルドする場合:

```bash
./scripts/build-app.sh
open "build/Hark Server.app"
```

メニューバーに波形のアイコンが出ます。クリックすると、接続先の URL と処理の履歴が表示されます。下の「**Settings…**」を開くと、ポートの変更と「**Start automatically when I log in**」（ログイン時に自動で起動）のチェックボックスがあります。自動起動を使うときは、アプリをアプリケーションフォルダに置いてください。

### ポートの変更

初期値は `8082` です。他のアプリがすでに使っている場合、Hark Server はそのポートでは起動せず、空いているポートを提案します。「**Use port 8083 instead**」を押せば、そのポートに切り替わります。「Settings…」の「Port」欄に 1024〜65535 の好きな番号を入れて変えることもできます。変えたら、Chrome 拡張など接続する側の設定も新しいポートに合わせてください。

他のアプリが閉じた直後のポートに戻すと、macOS が最大 30 秒ほどポートを押さえていることがあります。その間 Hark Server は待機し、空いたら自動で起動します。

## HTTP API（OpenAI 互換）

ベース URL: `http://127.0.0.1:8082/v1`

```bash
curl http://127.0.0.1:8082/v1/audio/transcriptions \
  -F file=@meeting.m4a -F language=ja -F response_format=srt
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8082/v1", api_key="not-needed")
with open("meeting.m4a", "rb") as f:
    print(client.audio.transcriptions.create(model="apple-on-device", file=f, language="ja").text)
```

`response_format` は `json`、`text`、`verbose_json`（区間ごとの時刻付き）、`srt`、`vtt` に対応しています。言語の自動判定はできないので、`language` を指定してください（省略時はシステムの言語）。

## WebSocket API（逐次文字起こし）

`ws://127.0.0.1:8082/v1/stream` に接続し、`{"type":"start","language":"ja-JP","sample_rate":16000}` を送ってから、16bit・モノラルの PCM をバイナリで送り続けます。認識途中の結果は `partial`、確定した文は `final`（時刻付き）として返ってきます。詳しくは [英語版 README](README.md#websocket-streaming-api) を参照してください。

## セキュリティ

`127.0.0.1` でのみ待ち受けます。さらに、閲覧中の Web ページから悪用されないように、次の2つを確認します。

- `Host` ヘッダーが localhost であること（DNS リバインディング対策）
- ブラウザからのリクエストは、拡張機能か localhost のページからのものに限ること

## ライセンス

[MIT](LICENSE)
