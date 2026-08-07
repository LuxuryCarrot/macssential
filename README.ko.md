[English](README.md) | [한국어](README.ko.md) | [日本語](README.ja.md) | [简体中文](README.zh-Hans.md)

# macssential

macssential은 macOS 14+용 메뉴바 유틸리티로, macOS의 불편한 기본 동작을 클릭 한
번으로 직접 제어할 수 있게 해줍니다 — 모니터 간 Dock 이동, 키보드 반복 속도,
스크롤 방향, 파일명 정규화 등. 각 기능은 독립적인 모듈이라 시스템 설정을 뒤질
필요 없이 메뉴바에서 바로 켜고 끌 수 있습니다.

> macssential은 [MIT 라이선스](LICENSE)로 공개된 오픈소스입니다.

## 기능

- **Dock 고정** — Dock를 특정 모니터에 고정해 디스플레이 사이를 오가지 않게
  합니다.
- **Dock 자동 숨기기** — Dock을 자동으로 숨기고 표시합니다.
- **최근 앱 숨기기** — Dock에서 최근 사용한 앱 영역을 제거합니다.
- **숨김 파일** — Finder에서 숨김 파일을 표시합니다.
- **키 반복 속도** — 시스템 설정이 허용하는 것보다 더 빠른 키 반복 속도를
  사용할 수 있습니다.
- **스크롤 방향** — 마우스와 트랙패드의 스크롤 방향을 따로 설정합니다.
- **스크린샷 자동 복사** — 스크린샷을 파일로 저장하는 대신 클립보드에 바로
  복사합니다.
- **한글 파일명 정규화** — 자소가 분리된(NFD) 파일명을 NFC로 자동 변환해
  한글·일본어 등에서 깨져 보이는 파일명을 바로잡습니다.

## 사용 방법

**메뉴바 패널.** 메뉴바의 ✱ 아이콘을 클릭하면 드롭다운 패널이 열립니다. 클릭
한 번으로 기능을 켜고 끌 수 있으며, 켜진 모듈은 슬라이더·옵션 같은 세부 설정을
패널 안에 바로 표시합니다.

**설정 창.** 패널 하단의 설정(톱니바퀴) 버튼을 클릭하면 설정 창이 열립니다.
일반 / 모듈 / 패널 / 정보 네 개의 탭이 있으며, 모듈 탭에서는 앱 전체에서
모듈을 켜고 끌 수 있습니다.

**패널 구성하기.** 패널 탭에서는 메뉴바 패널에 표시할 모듈을 직접 골라, 실제로
사용하는 기능만 보이게 만들 수 있습니다.

## 설치

### Homebrew

```sh
brew tap luxurycarrot/tap
brew install macssential
```

(`brew tap`은 최초 한 번만 실행하면 됩니다. 최근 Homebrew 버전에서는 tap을
신뢰할지 확인을 요청할 수 있습니다. 이후에는 `brew install macssential`,
`brew upgrade macssential`처럼 짧은 이름으로 사용할 수 있습니다.)

한 줄로 설치하려면:

```sh
brew install --cask luxurycarrot/tap/macssential
```

### 직접 다운로드

1. [Releases 페이지](https://github.com/LuxuryCarrot/macssential/releases)에서
   최신 DMG를 다운로드합니다.
2. DMG를 열고 `macssential.app`을 `응용 프로그램` 폴더로 드래그합니다.
3. macssential을 실행하면 메뉴바에 나타납니다.

## 업데이트

macssential은 [Sparkle](https://sparkle-project.org/)을 통해 자동으로
업데이트됩니다. 앱이
`https://luxurycarrot.github.io/macssential/appcast.xml` 피드를
확인해 새 버전을 앱 안에서 바로 제안하므로, 수동으로 다운로드할 필요가
없습니다.

## 권한

Dock 고정, 스크롤 방향, 스크린샷 자동 복사 모듈은 손쉬운 사용 권한이
필요합니다. **시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용**에서 권한을
허용해 주세요 — 필요할 때 앱이 해당 위치로 안내합니다. 나머지 모듈은 별도의
권한 없이 동작합니다.

## 요구 사항

- macOS 14 Sonoma 이상
