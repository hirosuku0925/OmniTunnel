# OmniTunnel

Android、Windows、macOS、Linux 向け Flutter OpenVPN クライアントの骨組みです。iOS の VPN 接続は対象外ですが、UI 確認用に iOS Simulator build artifact を CI で生成します。画面は `.ovpn` ファイルまたは貼り付けた設定を使い、接続・切断状態を表示します。

## セットアップ

Flutter SDK 3.47.6 と、iOS build 時は Xcode を用意してください。Flutter の native runner はリポジトリに含めています。再生成する場合はプロジェクトルートで次を実行します。

```sh
flutter create --platforms=android,windows,macos,linux,ios --project-name omnitunnel --org com.example .
flutter pub get
flutter run -d linux
```

依存パッケージは `openvpn_flutter`（Android VPN engine）と `file_picker`（`.ovpn` 選択）です。

## 構成

```text
lib/
	main.dart                      UI と Android/desktop の振り分け
	desktop_openvpn_controller.dart OpenVPN CLI の起動、ログ監視、停止
android/app/src/main/             Flutter が生成する Android runner
windows/                          Windows runner とアプリ同梱 OpenVPN
macos/                            macOS runner と署名済み helper/OpenVPN
linux/                            Linux runner と OpenVPN/polkit helper
ios/                              iOS Simulator build 用 runner
```

`openvpn_flutter` は pub package 内に Android の `VpnService` 宣言を持ち、Gradle の Manifest merge で取り込みます。Windows/macOS/Linux では `DesktopOpenVpnController` が `Process.start` で OpenVPN CLI を起動します。実運用では OS ごとの特権 helper/service と配布バイナリが必要です。Dart のプロセス起動だけで TUN 権限が得られるわけではありません。

## Android

- 接続時に Android の VPN 同意ダイアログが出ます。プラグインの `requestPermissionAndroid()` を通して要求します。
- `openvpn_flutter` が service と `ACCESS_NETWORK_STATE` 等を Manifest merge します。アプリ側 Manifest に同じ `OpenVPNService` を重複宣言しないでください。
- プラグインの Android README に従い、Kotlin `MainActivity` の `onActivityResult` で `OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK)` を呼びます。Flutter/Android embedding のバージョンに応じたコールバック互換性を確認してください。
- Android 14 以降の foreground service type/権限を plugin manifest と照合してください。AAB 配布時は README の `android:extractNativeLibs="true"` と JNI packaging 設定も確認します。
- OpenVPN engine はプラグインに含まれるため、desktop 用 CLI バイナリは不要です。

## Windows

- 配置候補はアプリ実行ファイルの隣の `openvpn/openvpn.exe` です。開発時は PATH 上の `openvpn.exe` または `OMNITUNNEL_OPENVPN` 環境変数で指定できます。
- TUN driver と OpenVPN Interactive Service をインストーラーで構成し、service/helper 経由で接続するのが推奨です。単純に `openvpn.exe` を子プロセス起動するだけでは、標準ユーザーに必要な route/TUN 権限がありません。
- UAC の `requireAdministrator` をアプリ全体に要求する方式は毎回の昇格や権限範囲が広くなるため、署名済みの限定 helper を優先してください。

## macOS

- 配置候補は `.app/Contents/Frameworks/openvpn` または `.app/Contents/Resources/openvpn` です。
- TUN 接続には Network Extension entitlement を持つ system extension、または署名・登録された privileged helper (SMJobBless 等) が必要です。一般の Flutter 子プロセスに `sudo` を付ける方式は採用しないでください。
- helper と OpenVPN バイナリを codesign/notarize し、Intel/Apple Silicon の各アーキテクチャを用意します。

## Linux

- 配置候補はアプリ実行ファイル隣の `openvpn/openvpn` または bundle の `lib/omnitunnel/openvpn` です。開発時は `/usr/sbin/openvpn`、PATH、または `OMNITUNNEL_OPENVPN` を使えます。
- `/dev/net/tun` と `CAP_NET_ADMIN` が必要です。polkit で認可する限定 helper または system service を用意し、アプリから `sudo` とパスワードを扱わないでください。

## Desktop controller の注意

- `.ovpn` と認証情報を一時ディレクトリへ書き、OpenVPN 終了時に削除します。POSIX ではディレクトリ/file を `0700`/`0600` にします。Windows では OS の ACL で一時領域を保護する必要があります。認証情報をログやコマンドライン引数に出しません。
- 設定が相対パスの `ca`/`cert`/`key`/`tls-auth` ファイルを参照する場合、元の `.ovpn` と同じディレクトリを working directory にします。貼り付け設定では参照ファイルを解決できないため、inline block を使うか、参照ファイルを一緒に管理する仕組みを追加してください。
- `lib/desktop_openvpn_controller.dart` は OpenVPN CLI を直接起動する開発用骨組みです。管理者昇格、helper との IPC、service の監視・終了処理は各 OS の native runner 側で実装してください。OpenVPN バイナリの同梱・再配布は upstream のライセンスと各 OS の署名要件を確認してください。

## iOS Simulator CI（ビルドのみ）

`.github/workflows/build-ios-sim.yml` は push、pull request、手動実行時に `macos-latest` 上で Debug simulator build を実行します。Flutter は Simulator 向け Release build をサポートしないため Debug を使います。`--no-codesign` を指定するため、実機向け署名証明書や Provisioning Profile は不要です。成功すると Actions の run ページに `OmniTunnel-ios-simulator` という ZIP artifact が保存されます。

現行 runner の deployment target は iOS 15.0、Bundle ID は `com.example.omnitunnel` です。CI では Flutter の依存解決と Xcode project の設定を使い、CocoaPods の手動実行はしません。

Artifact を macOS にダウンロードして展開し、Simulator を起動してから次を実行します。`<device-udid>` は `xcrun simctl list devices available` で表示される Simulator の ID に置き換えてください。

```sh
xcrun simctl boot <device-udid>
xcrun simctl install booted Runner.app
xcrun simctl launch booted com.example.omnitunnel
```

この artifact は画面確認専用です。`openvpn_flutter` の実際の iOS VPN 接続には Runner と Packet Tunnel Extension の App Groups / Network Extensions capability、OpenVPNAdapter の組み込みが別途必要です。同 package の説明では VPN 接続テストに Simulator は使えず、実機が必要です。