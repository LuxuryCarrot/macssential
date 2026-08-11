[English](README.md) | [한국어](README.ko.md) | [日本語](README.ja.md) | [简体中文](README.zh-Hans.md)

<p align="center">
  <img src="docs/assets/logo.png" width="96" alt="macssential logo">
</p>

<h1 align="center">macssential</h1>

<p align="center"><em>macOSの標準動作を、メニューバーから思いのままに。</em></p>

<p align="center">
  <a href="https://github.com/LuxuryCarrot/macssential/releases"><img src="https://img.shields.io/github/v/release/LuxuryCarrot/macssential?style=flat-square" alt="GitHub release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square" alt="Platform: macOS 14+">
  <img src="https://img.shields.io/badge/homebrew-cask-orange?style=flat-square" alt="Homebrew cask">
  <a href="https://ko-fi.com/luxurycarrot"><img src="https://img.shields.io/badge/Ko--fi-support-ff5e5b?style=flat-square&logo=kofi&logoColor=white" alt="Support on Ko-fi"></a>
</p>

macssentialはmacOS 14+向けのメニューバーユーティリティです。モニター間のDockの
移動、キーボードのリピート速度、スクロール方向、ファイル名の正規化など、macOSの
不便なデフォルト動作をワンクリックで自分好みにコントロールできます。各機能は
独立したモジュールになっており、システム設定を探し回ることなく、メニューバーから
そのままオン/オフを切り替えられます。

<p align="center"><img src="docs/assets/demo.gif" width="600" alt="macssential demo"></p>

> macssentialは[MITライセンス](LICENSE)のオープンソースです。

## 機能

- **Dock固定** — Dockを特定のモニターに固定し、ディスプレイ間を勝手に移動
  しないようにします。
- **Dockの自動非表示** — Dockを自動的に隠したり表示したりします。
- **最近のアプリを非表示** — Dockから「最近使ったアプリ」の領域を取り除きます。
- **隠しファイル** — Finderで隠しファイルを表示します。
- **キーリピート** — システム設定の上限を超える高速なキーリピートを使えます。
- **スクロール方向** — マウスとトラックパッドのスクロール方向を別々に設定
  できます。
- **スクリーンショット自動コピー** — スクリーンショットをファイルとして保存
  せず、クリップボードに直接コピーします。
- **ファイル名正規化** — 濁点・半濁点が分解されたファイル名（NFD）をNFCに
  自動変換し、日本語や韓国語などで文字化けして見えるファイル名を修正します。


## 機能デモ

<details><summary><b>Dock固定</b></summary>
<p align="center"><img src="docs/assets/demo-dock-anchor.gif" width="600" alt="Dock固定 demo"></p>
</details>
<details><summary><b>Dockの自動非表示</b></summary>
<p align="center"><img src="docs/assets/demo-dock-autohide.gif" width="600" alt="Dockの自動非表示 demo"></p>
</details>
<details><summary><b>最近のアプリを非表示</b></summary>
<p align="center"><img src="docs/assets/demo-hide-recent-apps.gif" width="600" alt="最近のアプリを非表示 demo"></p>
</details>
<details><summary><b>隠しファイル</b></summary>
<p align="center"><img src="docs/assets/demo-hidden-files.gif" width="600" alt="隠しファイル demo"></p>
</details>
<details><summary><b>キーリピート</b></summary>
<p align="center"><img src="docs/assets/demo-key-repeat.gif" width="600" alt="キーリピート demo"></p>
</details>
<details><summary><b>スクロール方向</b></summary>
<p align="center"><img src="docs/assets/demo-scroll-direction.gif" width="600" alt="スクロール方向 demo"></p>
</details>
<details><summary><b>スクリーンショット自動コピー</b></summary>
<p align="center"><img src="docs/assets/demo-screenshot-auto-copy.gif" width="600" alt="スクリーンショット自動コピー demo"></p>
</details>
<details><summary><b>スクリーンショット保存先のカスタマイズ</b></summary>
<p align="center"><img src="docs/assets/demo-screenshot-save-path.gif" width="600" alt="Screenshot save path demo"></p>
<p>パネルの「Also save to folder」→「Choose…」から任意のフォルダを指定できます。この機能はmacssentialの実行中のみ動作し、macOSのシステム設定は一切変更しません — アプリを終了・削除すればすぐに標準の動作（デスクトップ保存）に戻ります。</p>
</details>
<details><summary><b>ファイル名正規化</b></summary>
<p align="center"><img src="docs/assets/demo-filename-normalizer.gif" width="600" alt="ファイル名正規化 demo"></p>
</details>

## 使い方

**メニューバーパネル。** メニューバーの✱アイコンをクリックするとドロップダウン
パネルが開きます。クリック一つで機能のオン/オフを切り替えられ、オンにした
モジュールはスライダーやオプションなどの操作項目をパネル内にそのまま表示します。

**設定ウインドウ。** パネル下部の設定（歯車）ボタンをクリックすると設定
ウインドウが開きます。一般 / モジュール / パネル / 情報 の4つのタブがあり、
モジュールタブではアプリ全体でモジュールを有効/無効にできます。

**パネルのカスタマイズ。** パネルタブでは、メニューバーパネルに表示する
モジュールを自由に選べるので、実際に使う機能だけを並べておけます。


<p align="center"><img src="docs/assets/demo-panel-customize.gif" width="600" alt="Panel customization demo"></p>

## インストール

### Homebrew

```sh
brew tap luxurycarrot/tap
brew install macssential
```

（`brew tap`は初回のみ必要です。最近のHomebrewではtapを信頼するかどうかの確認を
求められることがあります。以降は`brew install macssential`や
`brew upgrade macssential`のように短い名前で使えます。）

ワンライナーでインストールする場合:

```sh
brew install --cask luxurycarrot/tap/macssential
```

### 直接ダウンロード

1. [Releasesページ](https://github.com/LuxuryCarrot/macssential/releases)
   から最新のDMGをダウンロードします。
2. DMGを開き、`macssential.app`を`アプリケーション`フォルダにドラッグします。
3. macssentialを起動すると、メニューバーに表示されます。

## アップデート

macssentialは[Sparkle](https://sparkle-project.org/)により自動的に更新されます。
アプリが
`https://luxurycarrot.github.io/macssential/appcast.xml`
のフィードを確認し、新しいバージョンをアプリ内で提案するので、手動での
ダウンロードは不要です。

## 権限

Dock固定、スクロール方向、スクリーンショット自動コピーの各モジュールには
アクセシビリティ権限が必要です。**システム設定 > プライバシーとセキュリティ >
アクセシビリティ** で許可してください — 必要になったタイミングでアプリが案内
します。それ以外のモジュールは特別な権限なしで動作します。

## 動作環境

- macOS 14 Sonoma 以降

## フィードバック

バグの報告や機能のリクエストは
[Issues](https://github.com/LuxuryCarrot/macssential/issues/new/choose)
からお願いします。質問やアイデアの共有は
[Discussions](https://github.com/LuxuryCarrot/macssential/discussions)
をご利用ください。

## サポート

macssential は無料のオープンソースプロジェクトです。このアプリが Mac
ライフを快適にしてくれたら、[Ko-fi](https://ko-fi.com/luxurycarrot)
でコーヒー一杯分の支援をいただけると嬉しいです。☕

いただいたサポートは、macssentialがセキュリティ警告なしで動作するためのコード署名・公証、つまりApple Developerメンバーシップの維持に直接使われます。

<p align="center">
  <a href="https://ko-fi.com/luxurycarrot"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Buy Me a Coffee at ko-fi.com" height="40"></a>
</p>


---

<sub>macssential は独立したオープンソースプロジェクトであり、Apple Inc. との提携、承認、後援を受けていません。Mac および macOS は Apple Inc. の商標です。</sub>
