# 반달 iPad — 로그인·동기화·구독 2단계 설계안

- 작성일: 2026-10-30
- 기준
  - 코드: `main` 747808b와 현재 작업 트리
  - 문서: 1단계 보고서(`docs/ipad-sync-phase1-survey-2026-10-29.md`), 데스크톱 1단계 보고서(`bandal:docs/sync-desktop-survey-2026-10-29.md`), 공통 스펙 v2(2026-10-30)
- 범위
  - 설계만 했다. 앱 코드는 바꾸지 않았고 실험 브랜치도 만들지 않았다.
  - 실측은 두 가지다(§13): 실제 iPad DB 사본으로 잰 v2 필기 파일 크기, `auth.bandal.io`의 OIDC issuer.
  - 공통 스펙 v2는 고치지 않았다. 스펙이 설계안에 맡긴 항목은 §12.1, 스펙 문장을 바꿔야 하는 항목은 §12.2에 모았다.
- 표기: `파일:줄`은 이 저장소 기준이다. 데스크톱 저장소는 `bandal:` 접두로 적었다.

---

## 0. 요약

1. **구조.**
   - `SyncEngine`(actor) 하나가 `SyncProvider`(iCloud 또는 Drive) 위에서 돈다.
   - bandal.db와 스펙 v2 사이의 변환은 `NativeCloudSyncRepository`가 맡는다. 이 저장소는 기존 저장소 큐에서 실행된다.
   - 머지 규칙은 I/O가 없는 순수 함수(`SyncMerge`)로 둔다.
   - 필기 엔진과 렌더러는 건드리지 않는다.
2. **변경 감지는 `updated_at`이 아니라 내용 해시로 한다.**
   - 필기는 SQLite 트리거가 dirty id를 모은다. 과목·문서·md·PDF는 1.5초 idle마다 재조정한다.
   - 내보낼지는 "동기화 형태의 해시"가 마지막으로 주고받은 값과 다른지로 정한다.
   - 이유: 앱 안에서 이름을 바꾸면 `repointDatabase`가 그 문서의 모든 필기 행 `updated_at`을 지금 시각으로 바꾼다(`App/Native/Storage/NativeLibraryRepository.swift:697-707`).
   - `updated_at` 기준이면 이름 변경 한 번에 문서 전체 필기가 새 t로 다시 올라간다. 그러면 다른 기기가 그사이 고친 같은 id를 낡은 내용이 이긴다.
3. **필기 객체는 `pdf_drawings` 행 그대로다.**
   - `data`와 `style`은 중첩 그대로 두고 `t`, `created`, `del`만 더한다. 이미지는 `relPath` 대신 `sha256`과 `ext`를 쓴다.
   - 실제 iPad 데이터로 쟀다. 객체 19,869개, 샘플 944k개다.
     - 원래 정밀도: 페이지 파일 gzip 중앙값 386 KB, 최대 2.5 MB, 1 MB를 넘는 페이지 11/44개
     - 소수점 반올림: 중앙값 144 KB, 최대 864 KB. 2.7배 작다.
   - 정밀도는 결정이 필요하다(§14).
4. **노트 충돌 판정에는 `md_base`가 필요하다(변경 제안 §12.2-1).**
   - 스펙의 "양쪽이 각자 수정했으면 충돌 사본" 규칙을 손실 없이 판정하려면, 각 수정이 어느 버전에서 출발했는지 알아야 한다.
   - 이 정보가 없으면, 이미 올린 동시 수정이 사본 없이 덮이는 순서가 생긴다(§3.4).
5. **auth 도메인만 바꾸면 로그인이 전부 실패한다.**
   - `auth.bandal.io`는 이미 프로젝트로 CNAME돼 있다. 그런데 이 주소의 OIDC 문서가 알리는 issuer는 `https://ukacrkcwiqafwpppshxb.supabase.co/auth/v1`이다(2026-10-30 실측).
   - 지금 코드는 iss가 "접속 주소 + `/auth/v1`"이어야 통과시킨다(`App/Desktop/DesktopAccountService.swift:462`).
   - 그래서 접속 주소를 바꾸면 모든 로그인을 거부한다. issuer를 별도 설정값으로 분리한다(§6.3).
6. **계정 잠금은 파일을 무시하는 것만으로 풀린다.**
   - 개발 iPad 백업에 `account-binding.json`(2026-10-17)이 실제로 있다.
   - 바인딩은 자료를 옮기지 않는다. 그래서 파일을 무시하기만 하면 업데이트 직후 같은 자료가 그대로 보인다.
   - 파일은 지우지 않는다. PR을 되돌려도 안전하다(§6.2).
7. **CommonSync는 서비스 객체를 만들지 않는 방식으로 멈춘다.**
   - 대상: `App/Native/NativePlatformServices.swift:107`(동기화), `:115`(서버 판정 구독)
   - 배포 사용자는 동기화가 숨겨져 있었다. 서버에 올라간 자료가 없다.
   - 서버 쪽 차단은 데스크톱 철거와 함께 정한다(§7).
8. **구독은 StoreKit 2로 기기에서 판정한다.**
   - 페이월은 SwiftUI `SubscriptionStoreView`로 만든다. 복원 버튼과 약관 링크가 들어 있다.
   - 무료 한도는 생성 채널 8개를 `DesktopRuntime` 디스패치 한 곳에서 검사한다.
   - "이 iPad에서 만든 것"은 새 매핑 테이블의 `origin`으로 센다(§8).
9. **AI 정책을 적용하려면 호스팅 AI 서버가 먼저 있어야 한다.**
   - 지금 iPad AI는 BYOK다. 사용자가 등록한 API 키로 OpenAI·Anthropic·Google을 직접 부르고, 로그인이 없다(`App/Desktop/DesktopAIService.swift:5-6, 65`).
   - "로그인 필수, 서버가 월 한도"는 반달 키로 부르는 호스팅 AI가 있어야 성립한다. 그런 서버는 아직 없다.
   - 서버 일정과 BYOK 처리는 결정이 필요하다(§8.5).
10. **노트에 페이지를 추가하는 것도 재구성이다.**
    - 손글씨 노트의 "페이지 추가"도 `pdf:restructure`를 쓴다(`App/Native/NativePDFWorkspace.swift:1700-1707`). 끝에 추가하는 호출은 `:647`이다.
    - 스펙대로 막으면 동기화 중인 노트에 페이지를 늘릴 수 없다.
    - 끝에 추가하는 것은 기존 쪽 번호를 바꾸지 않는다. 그래서 예외로 허용하자고 제안한다(§12.2-2).

---

## 1. 아키텍처

### 1.1 구성

```
UI (설정 > 동기화, 초기 연결 시트)
  │  IPC "cloudSync:*"
SyncEngine (actor, 앱에 1개)
  ├─ SyncProvider ─┬─ ICloudProvider  (FolderProvider + 파일 조정·감시)
  │                └─ DriveProvider   (Drive REST v3)
  ├─ SyncMerge     (순수 함수: (t, device_id) 비교, 메타 LWW, 필기 LWW, 노트 head)
  └─ NativeCloudSyncRepository  (DesktopRuntime 저장소 큐에서 실행)
       bandal.db ↔ 스펙 v2 객체 변환, cloud_sync_* 테이블
```

- 기존 구조(IPC 채널 + 직렬 저장소 큐)를 그대로 따른다. DB를 만지는 일은 모두 저장소 큐에서 한다.
- 새 파일 후보: `App/Sync/`(`SyncEngine`, `SyncProvider`, `FolderProvider`, `ICloudProvider`, `DriveProvider`, `GoogleOAuth`, `SyncMerge`, `Gzip`), `App/Native/Storage/NativeCloudSyncRepository.swift`.
- gzip은 시스템 zlib로 직접 처리한다(`deflateInit2`/`inflateInit2`, windowBits 31). 저장소에는 gzip 도우미가 없고, 의존성은 추가하지 않는다.

### 1.2 SyncProvider

```swift
protocol SyncProvider: AnyObject, Sendable {
    var kind: SyncProviderKind { get }                        // .iCloud, .drive
    func availability() async -> SyncAvailability              // .ready(identity), .signedOut, .unavailable(reason)
    func open() async throws -> SyncRootIdentity               // 루트 폴더 확보(없으면 생성). bandal.json은 엔진이 쓴다
    func index() async throws -> [SyncRemoteFile]              // 전체 목록
    func changes() -> AsyncStream<Void>                        // "목록이 바뀌었을 수 있음" 신호
    func read(_ path: String) async throws -> Data             // 필요하면 내려받은 뒤 읽기
    func download(_ path: String, to file: URL) async throws   // 큰 파일(PDF)
    func write(_ data: Data, to path: String) async throws     // 자기 파일 생성·교체(원자적)
    func upload(_ file: URL, to path: String) async throws     // 큰 불변 파일(PDF)
}
struct SyncRemoteFile { let path: String; let size: Int64; let version: String }
```

- `path`는 루트 기준 스펙 경로다. 예: `ink/<doc>/<page>/<dev>-<seq>.json.gz`.
- `version`은 변경 감지용 값이다.
  - iCloud: `NSMetadataItemFSContentChangeDateKey`와 크기
  - Drive: `md5Checksum`
  - 엔진은 처리한 파일의 version을 `cloud_sync_seen`에 두고, 바뀐 파일만 다시 읽는다.
- 삭제 API는 없다. 스펙상 파일을 지우지 않는다(삭제는 tombstone, compaction은 범위 밖).
- 구현은 둘이고, 테스트용으로 `FolderProvider`(로컬 폴더)를 하나 더 둔다.
  - `ICloudProvider`는 `FolderProvider`에 NSFileCoordinator와 NSMetadataQuery를 더한 것이다. 그래서 테스트 대역이 실제 코드의 일부가 된다.

### 1.3 ICloudProvider

- **루트**
  - `FileManager.url(forUbiquityContainerIdentifier: "iCloud.app.bandal")` 아래 `Documents/`다. 이 호출은 메인 스레드 밖에서 한다.
  - nil이면 `.signedOut`이다. iCloud 로그인 없음, iCloud Drive 꺼짐, 이 앱의 iCloud Drive 꺼짐 중 하나다.
- **계정 식별**
  - `FileManager.default.ubiquityIdentityToken`을 아카이브해 `cloud_sync_state`에 둔다.
  - `NSUbiquityIdentityDidChange`로 계정이 바뀌면 동기화를 멈추고 §4.4 흐름으로 간다.
- **감시**
  - `NSMetadataQuery`를 쓴다.
    - `searchScopes`: `NSMetadataQueryUbiquitousDocumentsScope`
    - 술어: `%K LIKE '*'`(`NSMetadataItemFSNameKey`)
    - `operationQueue`: 전용 직렬 큐
  - 첫 `didFinishGathering` 전에는 아무것도 쓰지 않는다(seq 대조, §1.7).
  - `didUpdate`가 올 때마다 `changes()`로 신호를 보낸다.
- **내려받기**
  - 상태가 `NotDownloaded`면 `startDownloadingUbiquitousItem(at:)`을 부르고, `Current`가 될 때까지 기다린다.
  - 읽을 때는 `NSFileCoordinator.coordinate(readingItemAt:)`을 쓴다.
- **쓰기**: §1.5를 따른다.
- **업로드 오류**: `NSMetadataUbiquitousItemUploadingErrorKey`(예: iCloud 저장 공간 부족)를 동기화 상태로 올린다.
- **충돌 버전**
  - 파일은 만든 기기만 쓰므로 원칙상 생기지 않는다.
  - 예외는 두 기기가 동시에 `bandal.json`을 만드는 경우다. 내용이 같으므로 `NSFileVersion.removeOtherVersionsOfItem` 후 resolved로 표시한다.
- **백그라운드**
  - 앱이 쓴 파일의 업로드는 시스템이 백그라운드에서 이어 간다.
  - 원격 변경 감지는 v1에서 포그라운드에서만 한다.

### 1.4 DriveProvider

- **인증**
  - Google OAuth 2.0 설치형 앱 흐름이다. `ASWebAuthenticationSession`과 PKCE를 쓰고, SDK는 넣지 않는다.
  - 클라이언트: iOS 클라이언트 `<iOS Client ID>`
  - 리디렉트: `<iOS URL scheme>:/oauth2redirect`
  - 스코프: `https://www.googleapis.com/auth/drive.file`, `openid`, `email`(설정 화면에 연결된 계정을 보여 주는 용도)
- **토큰**
  - refresh token은 키체인에 둔다. account는 `drive.refresh`(프로필이면 `drive.refresh.<폴더명>`), 접근성은 `AfterFirstUnlockThisDeviceOnly`다.
  - access token은 메모리에만 둔다.
  - 반달 로그인 세션(`sync.session`)과 완전히 별개다. 반달에서 로그아웃해도 Drive 연결은 유지되고, 반대도 마찬가지다.
- **루트**
  - 내 드라이브 최상위의 `Bandal` 폴더다. 없으면 만든다.
  - `drive.file` 스코프라서 이 Cloud 프로젝트가 만든 파일만 보인다.
  - 같은 이름의 폴더가 여럿이면(두 기기가 동시에 만든 경우) 쓰기는 가장 오래된 폴더(`createdTime`, 다음 `id`)에 하고, 읽기는 모두 합친다.
- **하위 폴더도 같은 규칙이다.**
  - Drive는 한 폴더에 같은 이름을 허용한다. 그래서 두 기기가 `ink/<doc>/3/`을 동시에 만들 수 있다.
  - 경로마다 폴더 id를 여러 개 기억하고, 목록은 합쳐서 본다.
- **전체 목록**
  - `files.list`를 쓴다(`q=trashed=false`, `pageSize=1000`, `fields=nextPageToken,files(id,name,mimeType,parents,size,md5Checksum,modifiedTime,createdTime)`).
  - `drive.file`에서는 이 앱의 파일만 나온다. 그래서 페이지를 한 번 순회하면 트리 전체를 다시 만들 수 있다.
- **변경 감지**
  - `changes.getStartPageToken` 다음 `changes.list(includeRemoved=true)`를 쓴다. page token은 `cloud_sync_state`에 둔다.
  - 폴링 주기는 스펙대로다. 활성 30초, 유휴 5분, 포그라운드 진입 시 1회.
- **업로드**
  - 5 MB 미만은 multipart, 그 이상은 resumable이다. resumable 세션 URI는 outbox에 저장해 이어 올린다.
  - 새 파일은 `files.generateIds`로 미리 받은 id로 만든다. 그래서 재시도해도 같은 파일이 두 번 생기지 않는다. 409가 오면 md5를 비교해 성공으로 처리한다.
  - 자기 파일 교체는 `files.update`(media)다.
- **업로드 증폭 억제**
  - 세션 파일은 1.5초마다 다시 쓰일 수 있다(§1.8).
  - Drive는 같은 파일을 15초에 한 번까지만 올린다. 백그라운드로 갈 때와 "지금 동기화" 때는 바로 올린다.
  - 포맷과 무관한 제공자 내부 조절이다.
- **오류 처리**

  | 응답 | 처리 |
  |---|---|
  | 401 | 토큰 갱신 |
  | `invalid_grant` | "Google에 다시 연결해 주세요" |
  | 403/429 | 지수 백오프 |
  | 루트 404 | §4.4 "루트 사라짐" |

- **연결 해제**: 토큰을 revoke하고 키체인에서 지운다. Drive의 파일은 지우지 않는다.
- **백그라운드 폴링(BGAppRefresh)은 v1에서 하지 않는다.**
  - `UIBackgroundModes`를 추가하지 않아 심사 범위를 늘리지 않는다.
  - 포그라운드 진입 시 폴링으로 충분하다.

### 1.5 파일 쓰기 원자성

- **원칙.** 임시 파일은 동기화 루트 **밖**(앱 `tmp/`)에서 완성한다. 그다음 조정된 쓰기 안에서 한 번에 옮긴다. 그래서 루트 안에는 미완성 파일이 잠깐도 생기지 않는다. `.nosync` 같은 이름 규칙에 기대지 않는다.
  - 새 파일: `coordinate(writingItemAt: dest, options: .forReplacing)` 안에서 `moveItem(tmp → dest)`
  - 자기 파일 교체: 같은 조정 안에서 `replaceItemAt(dest, withItemAt: tmp)`
  - 앱 `tmp/`와 컨테이너는 같은 볼륨이므로 rename은 원자적이다.
- **Drive.** 업로드가 끝나야 파일이 보이므로 그 자체로 원자적이다.
- **한 번의 flush 안에서 쓰는 순서**
  1. `pdf/`, `assets/`(불변)
  2. `ink/`, `notes/`
  3. `log/`
  4. `devices/`

  읽는 쪽은 참조 대상이 아직 도착하지 않았을 수 있다고 가정한다. 그런 항목은 보류했다가 다시 시도한다(§2.7).
- **읽는 쪽 규칙**(합의 필요, §12.1-8): 스펙 패턴에 맞지 않는 이름은 무시한다. 점으로 시작하는 이름, `.tmp`, iCloud 플레이스홀더가 여기에 해당한다.

### 1.6 outbox와 변경 감지

- **필기**
  - 동기화가 켜져 있는 동안만 `pdf_drawings`에 INSERT·UPDATE·DELETE 트리거 3개를 둔다(§1.9). 트리거는 `cloud_sync_dirty('ink', id)`에 한 줄을 넣을 뿐이다.
  - 그래서 모든 쓰기 경로가 빠짐없이 잡힌다. 올가미, 도형 스냅, 지우개, 재구성, 이름 변경, 동기화 자신의 반영이 모두 포함된다.
  - 동기화를 끄면 트리거를 지운다. 꺼진 동안 표가 커지지 않게 하기 위해서다. 다시 켜면 전체 재조정을 한 번 한다.
- **과목·문서·md·PDF**
  - 다음 때 재조정한다.
    - 로컬 변경 뒤 1.5초 idle
    - 포그라운드 진입
    - 60초마다
  - 비교 대상: `courses`와 `materials_index`(pdf, note), 파일 stat을 마지막으로 주고받은 값(`cloud_sync_fields`, `cloud_sync_docs.hash`)과 비교한다.
  - 해시는 stat 정보가 바뀐 파일만 다시 계산한다. 기존 캐시 `native_file_hashes`를 그대로 쓴다(`App/Native/Storage/NativeRepositoryContext.swift:24, 36`).
- **로컬 변경 신호**
  - `DesktopRuntime`의 채널 디스패치 한 곳에서, 변경 채널이 성공하면 `SyncEngine.localChanged()`를 부른다. 읽기 전용 목록에 없는 채널이 변경 채널이다.
  - 이 호출은 1.5초 idle 타이머를 다시 걸 뿐이다. 잘못 불려도 비용은 재조정 한 번이다.
  - 앱 밖 변경(파일 앱)은 기존 5초 스캔이 내는 `materials:changed`(`App/Desktop/DesktopRuntime.swift:205`)로 받는다.
- **내보낼지 판정**
  - dirty 표시는 "확인할 대상"일 뿐이다.
  - 객체의 동기화 형태(§2.3, t 제외)의 SHA-256이 `cloud_sync_objects.hash`와 같으면 내보내지 않는다. 이렇게 하는 이유는 세 가지다.
    1. `repointDatabase`는 이름을 바꿀 때 그 문서의 필기 행 `updated_at`을 모두 지금 시각으로 바꾼다(`NativeLibraryRepository.swift:697-707`). 내용 해시로 판정하면 이 경우 아무것도 내보내지 않는다.
    2. 원격 반영도 트리거를 지나간다. 해시가 같으므로 메아리가 생기지 않는다.
    3. 가져올 때 iPad가 값을 고쳐 저장하는 경우가 있다(범위 밖 좌표 클램프, §2.3). 이때도 실제 저장된 값으로 해시를 남기므로 고친 값을 되돌려 쓰지 않는다.
- **실패와 재시도**
  - 제공자 쓰기가 성공한 뒤에만 같은 트랜잭션에서 상태를 갱신하고 dirty를 지운다.
  - 쓰기 직후 앱이 죽으면 다음 실행에서 같은 내용을 새 t로 다시 쓴다. 내용이 같으므로 해가 없다.

### 1.7 device_id · seq · clock

- **저장 위치**
  - `cloud_sync_state`에 둔다. 테이블은 데이터 루트, 즉 프로필마다 하나다. 키는 `device_id`, `next_seq`, `clock`이다.
  - `device_id`는 키체인에도 둔다. account는 `sync.device`(프로필이면 `sync.device.<폴더명>`), 접근성은 `AfterFirstUnlockThisDeviceOnly`이고 iCloud 키체인으로 동기화하지 않는다.
- **시작할 때 두 값을 대조한다.**

  | 상황 | 처리 | 이유 |
  |---|---|---|
  | DB와 키체인 값이 같다 | 그대로 쓴다 | |
  | DB에는 있는데 키체인에 없거나 값이 다르다 | 새 device_id를 만들고 seq를 1부터 시작한다 | 다른 기기에서 복원했거나 복사한 DB다. 같은 device_id로 두 기기가 쓰는 사고를 막는다 |
  | DB에 없다(재설치 포함) | 새로 만든다 | 옛 device_id의 파일은 "다른 기기" 파일로 읽힌다 |

- **seq**
  - 기기 전체에서 카운터 하나를 쓴다. log, ink, notes가 공유한다.
  - 처음 쓰기 전에 `next_seq = max(next_seq, 원격 목록에 있는 자기 device_id의 최대 seq + 1)`로 맞춘다. 같은 기기에서 오래된 백업을 복원해 seq가 뒤로 가도 자기 옛 파일을 덮지 않는다.
  - 그래서 첫 쓰기는 원격 목록이 다 모인 뒤에만 한다. iCloud는 첫 gathering이 끝난 뒤, Drive는 첫 전체 목록을 받은 뒤다.
- **clock**
  - 지금까지 본 모든 t(원격과 자기 것)의 최댓값이다.
  - 내보낼 t는 `max(지금 ms, clock + 1)`이고, 그다음 `clock = t`로 갱신한다.
  - 이렇게 하면 스펙의 `max(now, remote_max + 1)`을 만족하고, 같은 기기의 연속 수정도 단조 증가한다.

### 1.8 세션 파일과 flush

- **세션**: 앱이 포그라운드에 들어온 때부터 백그라운드로 갈 때까지다. 그동안 키마다 파일 하나를 계속 덮어쓴다.

  | 파일 | 키 |
  |---|---|
  | log | 기기 |
  | ink | (문서, 페이지) |
  | notes | 문서 |

- **새 파일**: 세션이 시작될 때, 또는 gzip 크기가 1 MB를 넘을 때(스펙) 새 seq로 만든다.
- **세션 파일 내용**
  - 이번 세션에 그 키로 내보낸 객체들의 최신 상태 전부다.
  - 지난 세션의 파일은 다시 쓰지 않는다. 같은 id의 새 버전은 새 파일에 더 큰 t로 들어간다.
- **업로드량 추정**(실측 기반, §13 E0)
  - 1시간 동안 한 페이지에 300획을 쓰면 세션 파일은 약 150 KB까지 자란다(반올림 기준).
  - 1.5초 idle마다 다시 쓰면 약 300번이다. 평균 75 KB × 300번이므로 약 22 MB를 올린다.
  - iCloud는 데몬이 업로드를 묶어 실제 전송량이 더 적을 수 있다(E7에서 실측).
  - Drive는 §1.4의 15초 제한으로 약 1/10이 된다.
  - 파일 크기 상한(1 MB)은 이 증폭에 거의 영향이 없다. 증폭을 정하는 것은 flush 횟수다.

### 1.9 로컬 테이블 (bandal.db, iPad 전용)

- 동결된 데스크톱 마이그레이션에 넣지 않는다. 저장소가 초기화할 때 `CREATE TABLE IF NOT EXISTS`로 만드는 기존 방식을 따른다(예: `App/Native/Storage/NativePDFRepository.swift:21-36`).

```sql
-- device_id, next_seq, clock, provider, root_identity, icloud_token, drive_root_id, drive_page_token, last_success_at
CREATE TABLE IF NOT EXISTS cloud_sync_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);

-- 과목: 로컬 UUID ↔ 동기화 UUID. 보통 같다. 초기 연결에서 이름이 같은 과목을 합칠 때만 다르다.
CREATE TABLE IF NOT EXISTS cloud_sync_courses(
  local_id TEXT PRIMARY KEY, sync_id TEXT NOT NULL UNIQUE,
  origin TEXT NOT NULL CHECK(origin IN ('local','remote')));

-- 문서: 동기화 UUID ↔ (과목, 경로). 앱 안 이름 변경은 repointDatabase가 함께 고친다.
CREATE TABLE IF NOT EXISTS cloud_sync_docs(
  sync_id TEXT PRIMARY KEY, course_id TEXT NOT NULL, rel_path TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('pdf','md')), hash TEXT,
  origin TEXT NOT NULL CHECK(origin IN ('local','remote')), UNIQUE(course_id, rel_path));

-- 메타 LWW 상태. _alive 필드가 upsert/delete를 나타낸다.
CREATE TABLE IF NOT EXISTS cloud_sync_fields(
  entity TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, value TEXT,
  t INTEGER NOT NULL, dev TEXT NOT NULL, PRIMARY KEY(entity, id, field));

-- 필기 LWW 상태. file은 이 객체의 최신판을 담은 자기 파일.
-- foreign_json은 iPad가 저장하지 못하는 객체(clip, 문서 미도착 등)의 원본.
CREATE TABLE IF NOT EXISTS cloud_sync_objects(
  id TEXT PRIMARY KEY, doc TEXT NOT NULL, page INTEGER NOT NULL, t INTEGER NOT NULL,
  dev TEXT NOT NULL, hash TEXT NOT NULL, file TEXT, foreign_json TEXT);

-- 노트 버전 그래프(log의 md 이벤트).
CREATE TABLE IF NOT EXISTS cloud_sync_note_versions(
  doc TEXT NOT NULL, hash TEXT NOT NULL, base TEXT, t INTEGER NOT NULL, dev TEXT NOT NULL,
  PRIMARY KEY(doc, hash, dev));

CREATE TABLE IF NOT EXISTS cloud_sync_dirty(kind TEXT NOT NULL, key TEXT NOT NULL, PRIMARY KEY(kind, key));
-- 처리한 원격 파일과 그 version
CREATE TABLE IF NOT EXISTS cloud_sync_seen(path TEXT PRIMARY KEY, version TEXT NOT NULL);
-- 자기 파일 목록. open=1이면 현재 세션 파일.
CREATE TABLE IF NOT EXISTS cloud_sync_files(path TEXT PRIMARY KEY, seq INTEGER NOT NULL, open INTEGER NOT NULL DEFAULT 0);
```

동기화가 켜져 있을 때만 두는 트리거:

```sql
CREATE TRIGGER IF NOT EXISTS cloud_sync_ink_insert AFTER INSERT ON pdf_drawings
  BEGIN INSERT OR IGNORE INTO cloud_sync_dirty VALUES('ink', NEW.id); END;
CREATE TRIGGER IF NOT EXISTS cloud_sync_ink_update AFTER UPDATE ON pdf_drawings
  BEGIN INSERT OR IGNORE INTO cloud_sync_dirty VALUES('ink', NEW.id); END;
CREATE TRIGGER IF NOT EXISTS cloud_sync_ink_delete AFTER DELETE ON pdf_drawings
  BEGIN INSERT OR IGNORE INTO cloud_sync_dirty VALUES('ink', OLD.id); END;
```

- `repointDatabase`의 표 목록(`NativeLibraryRepository.swift:697`)에 `cloud_sync_docs`를 넣는다. 한 줄 변경이다.
- 옛 CommonSync의 `ipad_sync_*` 테이블은 건드리지 않는다.
- **자기 파일 감사**
  - 포그라운드에 들어올 때 `cloud_sync_files`의 경로가 원격 목록에 없는지 확인한다. 사용자가 파일 앱에서 지운 경우다.
  - 없어진 파일에 있던 객체를 dirty로 표시하고 새 파일에 다시 쓴다. t는 바꾸지 않는다.

---

## 2. SyncAdapter (bandal.db ↔ 스펙 v2)

### 2.1 과목 (`course.upsert`, `course.delete`)

| 스펙 필드 | iPad | 비고 |
|---|---|---|
| id | `cloud_sync_courses.sync_id` | 보통 `courses.id`와 같다 |
| name | `courses.name` | |
| sort | `courses.sort_order` | |
| color | `courses.color` | |
| archived | `courses.archived` | bool |

- **동기화하지 않는 필드**: `group_id`(과목 그룹), `workspace_kind`, `folder_path`, `slug`, `source`.
- **원격 과목을 만들 때**: 관리형 과목(`Courses/<slug>`)으로 만들고 `workspace_kind`는 `course`로 둔다.
- **연결형 과목**(`source='linked'`, 외부 폴더): v1에서 빼는 것을 권장한다(결정 필요). 넣으면 다른 기기의 파일을 사용자의 외부 폴더에 쓰게 되고, 북마크 권한이 없으면 실패한다.
- **원격 삭제**: 로컬 삭제 경로를 쓰되 파일을 바로 지우지 않는다. `<데이터 루트>/SyncTrash/<날짜>/`로 옮긴다. 자동으로 비우지 않는다(결정 필요).
- **내보내기**: 바뀐 필드만 보낸다. 그래서 내가 모르는 필드를 덮어쓰지 않는다.

### 2.2 문서 (`doc.upsert`, `doc.delete`)

| 스펙 필드 | iPad |
|---|---|
| id | `cloud_sync_docs.sync_id` |
| course_id | 과목의 sync_id |
| type | `pdf`(materials kind `pdf`) 또는 `md`(kind `note`) |
| name | 확장자를 뺀 파일 이름 |
| rel_path | 과목 폴더 기준 경로 |
| pdf_sha256 | 현재 파일 바이트의 SHA-256 |
| md_hash | 노트 파일의 SHA-256(정규화 후, §2.5) |
| md_base | 변경 제안 §12.2-1 |

- **document_id 부여**(업그레이드 때 1회)
  - PDF: 바인딩의 `material_id`를 그대로 쓴다. 데스크톱도 같은 방식이다.
    - 아직 바인딩되지 않은 PDF는 동기화를 처음 켤 때 백그라운드에서 바인딩한다. 모든 PDF를 해시해야 하므로 업그레이드 시점에 하면 느리기 때문이다.
    - 개발 기기 실측: PDF 47개 중 37개가 이미 바인딩돼 있다.
  - md: 새 UUID를 만들어 `cloud_sync_docs`에 둔다. `materials_index.id`는 다시 스캔하면 바뀌는 캐시라서 쓰지 않는다.
- **재매칭**: 경로를 다시 스캔하다 새 경로를 보면, 새 UUID를 주기 전에 다음 순서로 기존 id를 찾는다.
  1. 같은 과목에서 경로가 사라진 문서(orphan) 중 해시가 같은 것이 있으면 그 id를 넘긴다.
  2. 후보가 여럿이면 파일 이름이 같은 것, 다음으로 경로가 가까운 것을 고른다.
  3. 살아 있는 문서의 id는 가져오지 않는다. 같은 PDF를 두 번 넣은 경우를 위한 규칙이다.
  - 한계: 앱 밖에서 이름과 내용을 동시에 바꾼 md는 새 문서가 되고, 옛 문서에는 `doc.delete`가 나간다. 내용은 잃지 않는다. 앱 안에서 바꾼 이름은 `repointDatabase`가 경로를 고치므로 이 경우에 해당하지 않는다.
- **경로 충돌**
  - 원격 문서의 rel_path에 이미 다른 로컬 문서가 있으면, 원격 문서를 `<이름> (<doc_id 앞 4자>).<ext>`로 옮기는 `doc.upsert`를 낸다.
  - 어느 기기가 처리해도 같은 값이 나오므로 결과가 하나로 모인다.
- **동기화하는 문서 종류**: 스펙대로 pdf와 md뿐이다.
  - v1 범위 밖(결정 필요, §14): 이미지·기타 파일, 화이트보드, 텍스트 하이라이트(`annotations`), PDF 페이지 노트 링크(`material_links`)

### 2.3 필기 객체 JSON 키 (데스크톱 팀과 합의할 초안)

- **원칙**: `pdf_drawings` 한 행을 그대로 쓴다.
  - 데스크톱 IPC 타입 `DrawingShape`(`bandal:src/shared/types/drawing.ts`)에서 courseId·relPath를 빼고 `t`, `created`, `del`을 더한 모양이다.
  - 두 앱의 열 구성은 같다(`bandal:src/main/db/migrations.ts:185-198`).
  - 그래서 변환은 사실상 이름 매핑뿐이고, 모르는 하위 필드도 그대로 지나간다.

```json
{
  "id": "0b9c2f4e-6f1d-4c8a-9a51-3f0c2d7e8b10",
  "kind": "ink",
  "page": 3,
  "t": 1793268000123,
  "created": 1793267990000,
  "style": {"color": "blue", "width": 0.0031, "opacity": 1, "fixedWidth": true},
  "data": {"inkVersion": 5,
           "points": [{"x": 0.41233, "y": 0.18877, "p": 0.612, "t": 4.2, "tiltX": 31.4, "tiltY": -8.0}]}
}
```

묘비(삭제)의 최소형:

```json
{"id": "0b9c2f4e-6f1d-4c8a-9a51-3f0c2d7e8b10", "page": 3, "t": 1793268100456, "del": true}
```

| 키 | 타입 | 출처 | 규칙 |
|---|---|---|---|
| id | string, 소문자 UUID | `pdf_drawings.id` | 필수 |
| kind | string | `kind` | `ink, highlighter, rect, ellipse, arrow, line, textbox, image`. 데스크톱 전용 `clip`은 v1 범위 밖이다. 받는 쪽은 모르는 kind를 보존만 한다 |
| page | int ≥ 1 | `page` | 문서의 현재 pdf_sha256 기준 쪽 번호. 파일 경로의 `<page>`와 다르면 객체 값을 따른다 |
| t | int, ms epoch | 내보낼 때 §1.7 clock | 필수. LWW 기준 |
| created | int, ms epoch | `created_at` | 그리는 순서(z-order)를 정한다. iPad는 필기를 `created_at` 순으로 읽는다(`App/Native/Storage/NativePDFRepository.swift:253`) |
| style | object | `style_json` 그대로 | 색은 이름 토큰 7종(`ink red orange yellow green blue violet`)이고 hex는 쓰지 않는다. 두 앱 모두 토큰만 저장한다. width는 표시 페이지 폭 대비 비율, opacity는 0..1이다. 그 밖에 fixedWidth(볼펜), 글상자 서식이 있다 |
| data | object | `data_json` 그대로 | `inkVersion`, `points[{x,y,p,t?,tiltX?,tiltY?}]`, `box`, `text`, `textRuns`, `image` |
| del | `true` | `deleted_at`, 또는 행이 없음 | 묘비. 위의 최소형만 있어도 된다 |

- **좌표**: 회전을 반영한 CropBox 기준 0..1이다(스펙 v2). 변환이 없다. 1단계 §2.4의 회전 테스트 4개를 그대로 쓴다.
- **압력과 시각**
  - p는 엔진 보정값 그대로다. iPad는 `clamp(force/max×2.5, 0.25, 1)`이고, 데스크톱은 압력이 없으면 0.5다.
  - 점의 `t`는 획 시작 기준 상대 ms다. 객체의 `t`(최종 수정 시각)와 이름이 같지만 놓이는 위치가 달라 섞이지 않는다.
  - 데스크톱 획에는 `t`, `tiltX`, `tiltY`가 없다. iPad 검증은 이 필드를 선택으로 받는다(`App/Native/Storage/NativePDFRepositoryValidation.swift:73-74`).
- **숫자 정밀도**: 결정 필요(§14-1).
  - 실측(§13 E0): 원래 정밀도는 샘플당 28.8 B다. 반올림하면(x·y 소수 5자리, p 3자리, t·tilt 1자리) 10.6 B다.
  - x·y 소수 5자리는 A4 폭에서 0.006 pt라서 눈에 띄지 않는다.
  - 반올림은 내보낼 때만 하고 로컬 행은 그대로 둔다. 엔진은 바뀌지 않는다.
  - 권장: 반올림.
- **굵기 1.6배 차이**
  - v2에서는 두 앱이 같은 행을 같은 V5 형상(`bandal:src/shared/inkV5`, `NativePDFInkGeometryV5.swift`)으로 그린다. 그래서 차이가 없어야 한다.
  - "획 입력 → 기대 외곽선" fixture로 두 구현이 허용오차 안에서 같은지 고정한다(§10).
- **받을 때 검증**: 원격 객체는 신뢰하지 않는 입력이다. 기존 `NativePDFRepositoryValidation` 규칙으로 검사한다.
  - 좌표가 [0,1]을 벗어나면 0~1로 클램프해 저장한다. 해시는 저장한 값으로 남기므로 되돌려 쓰지 않는다(§1.6 이유 3).
  - 그 밖에 검증을 통과하지 못하는 객체(clip, 모르는 kind, 형식 오류)는 `cloud_sync_objects.foreign_json`에 원본 그대로 보존하고 화면에 그리지 않는다. 손실 없이 나중 버전에서 반영할 수 있다.

### 2.4 이미지 객체와 assets

- **로컬**
  - 이미지는 과목의 `assets/` 폴더에 파일로 있다. 이름은 `이미지-<uuid>.png` 또는 `첨부-<uuid>.<ext>`다(`App/Native/NativeEditorMediaImport.swift:255-290`).
  - 객체는 `data.image.relPath`로 그 파일을 가리킨다. 데스크톱도 같다(`DrawingImageSource`).
- **동기화 형태**: `relPath`를 빼고 `sha256`(소문자 hex)과 `ext`를 넣는다. `label`, `widthPx`, `heightPx`는 그대로 둔다.

  ```json
  "image": {"sha256": "9f2c…", "ext": "png", "label": "칠판 사진", "widthPx": 1200, "heightPx": 900}
  ```

- **내보낼 때**: relPath의 파일을 해시한다. 원격에 `assets/<sha256>.<ext>`가 없으면 올린다.
- **받을 때**
  - 로컬 `assets/`에 해당 파일이 없으면 내려받는다. 바이트는 이름의 sha256과 대조한 뒤 `assets/<sha256>.<ext>`로 저장한다. relPath는 그 경로로 채운다.
  - asset이 아직 도착하지 않았으면 객체를 보류(foreign)한다. asset이 도착하면 반영한다.
- **공유 보드 자산**(`storage: "shared"`, `assetId`): v1에서 동기화하지 않고 보존만 한다.
- **허용 확장자**: png, jpg, jpeg, gif, heic, webp. 그 밖의 확장자는 보존만 한다.

### 2.5 텍스트 노트 스냅샷

- **파일**: `notes/<doc>/<dev>-<seq>.md`. 문서 전체를 담은 UTF-8 Markdown이다. 세션 동안 자기 파일을 덮어쓴다.
- **첨부 링크 정규화**
  - 내보낼 때 노트 안의 로컬 첨부 링크 `assets/<로컬 이름>`을 `../../assets/<sha256>.<ext>`로 바꾼다.
  - 이 상대 경로는 동기화 루트 안의 실제 파일을 가리킨다. 그래서 파일 앱이나 다른 Markdown 뷰어로 열어도 그림이 보인다.
  - 받을 때는 반대로 로컬 `assets/<sha256>.<ext>`로 바꾼다.
  - 데스크톱 1단계 제안(`assets/<sha256>.<ext>`)과는 경로 앞부분만 다르다. 합의가 필요하다(§12.1-5).
- **md_hash**: 정규화한 바이트의 SHA-256(소문자 hex)이다. 줄바꿈과 BOM은 바꾸지 않는다.
- **노트 이벤트**: 저장이 일어나면 log에 `doc.upsert {md_hash, md_base}`를 남긴다.
  - md_base는 이 수정이 출발한 버전이다. 이 기기가 직전에 반영했거나 내보낸 hash다(§3.4).
- **원격 승자 반영**
  - `notes:write`와 같은 경로를 쓴다. `withMaterialLock`, `atomicWrite`, `expectedMtime` 검사를 거친다(`NativeLibraryRepository.swift:499-513`).
  - 사용자가 같은 순간에 저장하면 충돌로 실패한다. 그러면 다음 주기에 다시 판정한다.
- **편집기가 열려 있을 때**
  - 저장하지 않은 초안이 있으면 반영을 미룬다.
  - 편집기가 저장하면 그 저장이 새 버전이 된다(base는 이전 승자). 그다음 §3.4 규칙으로 판정한다.
- **동기화 폴더 안의 노트 파일을 직접 고친 경우**: 반영하지 않는다. 내용 해시가 log의 md_hash와 맞지 않기 때문이다.
- **범위 밖**
  - `<!-- bandal:pdf-page-note … -->` 매니페스트 안의 courseId와 relPath는 다른 기기에서 맞지 않을 수 있다.
  - 본문은 동기화되지만 PDF와의 연결(`material_links`)은 v1에서 넘어가지 않는다.

### 2.6 PDF

- **올리기**
  - 원격 목록에 `pdf/<sha256>.pdf`가 없을 때만 올린다.
  - 원본으로는 `PDFOriginals/<sha>.pdf`를 쓴다. 이미 해시가 검증된 불변 사본이다. 없으면 과목 폴더의 파일을 쓴다.
  - iCloud에서는 같은 볼륨 안의 복사라서 APFS 클론이 될 것으로 본다. E5에서 실측한다.
- **받기**: `doc.upsert`의 pdf_sha256이 로컬과 다르면 다음 순서로 처리한다.
  1. `pdf/<sha>.pdf`를 받아 sha를 대조한다.
  2. 바인딩(`pdf_document_bindings`)을 `material_id = doc id`, `bound_sha = sha`로 먼저 맞춘다.
  3. 과목 폴더의 rel_path에 원자적으로 놓는다.

  바인딩을 먼저 맞추는 이유가 있다. 동기화가 바꾼 바이트가 "PDF 원본이 기존 필기와 다릅니다" 보호(`NativePDFRepository.swift:86-88`)에 걸리지 않게 하기 위해서다.
- **원본 불변**: 받은 PDF로 과목 폴더 파일을 바꿀 때도 이전 바이트는 `PDFOriginals`에 남긴다. 기존 재구성과 같은 규칙이다.
- **페이지 재구성**: §4.6을 보라.

### 2.7 원격 입력 검증 (보안)

동기화 루트의 파일은 신뢰하지 않는 입력이다. 파일이 손상됐거나, 다른 앱이 썼거나, 악의적으로 공유된 폴더일 수 있다.

- **rel_path**
  - 기존 경로 검증(`NativePDFRepositoryValidation.path`)을 쓴다. 절대 경로, `..`, 제어 문자를 거부한다.
  - `context.resolve(in:relativePath:)`로 확인해 과목 폴더 밖을 가리키면 거부한다.
  - 이 검사가 없으면 `"../../bandal.db"` 같은 값으로 데이터 루트의 파일을 덮을 수 있다.
- **id와 숫자**: id는 UUID 형식이어야 한다. page는 1..100000 정수, 숫자는 유한값이어야 한다.
- **크기 상한**: 다음을 넘는 파일은 건너뛴다(zip bomb 방지).

  | 파일 | 상한 |
  |---|---|
  | `.json.gz` | 압축 해제 후 64 MB |
  | log | 4 MB |
  | md | 16 MB |

- **해시 대조**: `pdf/`와 `assets/`는 내용의 SHA-256이 파일 이름과 같을 때만 쓴다.
- **파싱 실패**: 그 파일만 건너뛰고 기록한다. 파일이 다시 바뀌면 재시도한다. 나머지 동기화는 계속한다.
- **보류**: 참조 대상(과목, 문서, PDF, asset)이 아직 없는 항목은 보류한다. 대상이 도착하면 반영한다.
- **format**
  - `bandal.json`의 format이 2보다 크면 아무것도 읽거나 쓰지 않고 "앱 업데이트 필요"를 띄운다.
  - 2보다 작아도 멈춘다. v1 포맷은 출시된 적이 없다.

### 2.8 열린 문서에 원격 변경 반영

- **현황**: PDF 편집기에는 외부의 필기 변경을 듣는 경로가 없다. 편집기는 `materials:changed`를 듣지 않는다.
- **반영 방식**
  - 원격 필기는 DB에 바로 반영한다. DB가 진실이다.
  - 그 문서가 열려 있으면 해당 페이지를 "다시 읽을 페이지"로 표시한다. 입력 중인 제스처가 없고 저장 대기열이 비면 그 페이지의 객체를 저장소에서 다시 읽는다.
  - 엔진과 렌더러는 바꾸지 않는다. 문서를 처음 열 때 쓰는 로드 경로를 다시 부르는 방식이다. 정확한 호출 지점은 3단계 PR(f)에서 정한다.
- **반영 전에 편집기에서 옛 객체를 고친 경우**
  - 그 수정이 더 큰 t로 이긴다. "같은 id는 t가 큰 쪽이 이긴다"는 스펙의 의미와 같다.
  - 원격에서 새로 생긴 객체는 지워지지 않는다. 편집기는 객체 단위로 저장하기 때문이다.

---

## 3. 머지 엔진

### 3.1 순서와 clock

- 모든 비교는 `(t, device_id)`를 사전식으로 한다.
  - t가 크면 이긴다.
  - t가 같으면 device_id 문자열(소문자 UUID)이 큰 쪽이 이긴다.
  - 스펙의 "device_id 사전순"을 이렇게 해석했다(합의 필요, §12.2-3). 필기에도 같은 규칙을 쓴다.
- device_id는 파일 이름에서 얻는다. log는 디렉터리 이름, ink와 notes는 파일 이름 앞부분이다.
- 로컬 t는 §1.7의 clock으로 만든다.

### 3.2 메타 LWW

- 상태는 `(entity, id, field) → (value, t, dev)`다.
- `course.upsert`, `doc.upsert`: 이벤트의 각 필드마다, `(t, dev)`가 상태보다 크면 값을 덮는다. 이때 `_alive = true@(t, dev)`도 함께 적용한다.
- `course.delete`, `doc.delete`: `_alive = false@(t, dev)`를 적용한다.
- 살아 있는지는 `_alive`의 최종값으로 정한다. 더 큰 t의 upsert가 오면 되살아난다.
- 모르는 op는 무시한다. 모르는 필드는 상태에 보존한다. iPad는 바뀐 필드만 내보내므로 모르는 필드를 덮지도 않는다.
- 문서의 course_id가 아직 받지 않은 과목을 가리키면, 그 과목이 올 때까지 문서를 보류한다.

### 3.3 필기

- 상태는 `id → (t, dev, hash)`다.
- 원격 객체 o는 `(o.t, o.dev) > (s.t, s.dev)`일 때만 반영한다. `del`도 같은 비교로 처리한다.
- 같은 id가 다른 페이지 디렉터리에 있으면, 이긴 쪽의 page를 따른다.
- 반영한 뒤의 `hash`는 iPad에 실제로 저장된 값의 동기화 형태로 남긴다(§1.6 이유 3).

### 3.4 노트

- **버전 그래프**: log의 md 이벤트 `(doc, md_hash, md_base, t, dev)`를 `cloud_sync_note_versions`에 모은다.
- **본문 승자**: `md_hash` 필드의 LWW 값이다. 스펙의 "t 큰 쪽 승"과 같다.
- **충돌**
  - head는 그 문서에서 다른 버전의 base로 쓰이지 않은 hash다.
  - 승자가 아닌 head는 "양쪽이 마지막 동기화 이후 각자 수정한" 버전이다. head마다 충돌 사본을 만든다.
  - 사본 id: `UUIDv5(NS, "<doc_id>:<진 md_hash>")`. NS는 스펙에 고정할 네임스페이스 UUID다(합의 필요). 어느 기기가 만들어도 id가 같아 사본이 중복되지 않는다.
  - 사본 이름: `"<이름> (충돌 사본 <기기명>).md"`. 기기명은 그 버전을 쓴 기기의 `devices/<id>.json` name이다.
  - 그 id의 문서가 이미 있으면 다시 만들지 않는다. 살아 있든 삭제됐든 같다. 그래서 사용자가 지운 사본은 되살아나지 않는다.
  - 사본 내용은 진 버전을 쓴 기기의 노트 파일에서 읽는다. 그 기기가 다시 접속하지 않아도 파일은 루트에 남아 있다.
- **base가 필요한 이유**
  - base 없이 "내 로컬이 마지막 동기화 이후 바뀌었나"만 보면 손실이 생긴다. 다음 순서를 보자.
    1. 기기 A가 h1을 올리고 자기 이벤트를 처리한다. 그러면 A의 동기화 기준이 h1으로 옮겨진다.
    2. 그다음 B의 동시 수정 h2가 도착한다. t는 h2가 더 크다.
    3. A는 "로컬 변경 없음"으로 판단하고 h2를 그대로 받는다.
  - 결과적으로 h1은 사본 없이 사라진다. 루트의 파일에만 남는다.
  - base가 있으면 h2의 base가 h1이 아니라 h0이다. 그래서 h1이 head로 남고 사본이 된다.
- 텍스트 자동 병합은 하지 않는다.

### 3.5 테스트 케이스

기기 A·B, 시각은 t1 < t2 < t3이다. "같은 결과"는 두 기기 어느 쪽에서 처리해도 최종 상태가 같다는 뜻이다.

| ID | 규칙 | 입력 | 기대 |
|---|---|---|---|
| M1 | 필드 LWW | A가 과목 이름 변경@t1, B가 같은 과목 이름 변경@t2 | B의 이름. 같은 결과 |
| M2 | 필드 독립 | A가 이름 변경, B가 색 변경(동시) | 둘 다 반영 |
| M3 | 동률 | 같은 t, device_id `a…`와 `f…` | `f…`의 값 |
| M4 | 오래된 upsert | delete@t2, upsert@t1 | 삭제 유지 |
| M5 | 부활 | delete@t2, upsert@t3 | 살아남. 필드는 upsert 값과 이전 값의 합 |
| M6 | 모르는 op·필드 | `course.pin`, `fields.icon` | 무시 또는 보존. 오류 없음 |
| M7 | 순서 뒤바뀜 | 과목보다 문서 이벤트가 먼저 도착 | 보류했다가 과목 도착 후 반영 |
| M8 | clock | 원격 t가 로컬 시계보다 1시간 앞섬 | 다음 로컬 수정 t > 원격 t |
| M9 | 경로 충돌 | 원격 rel_path가 다른 로컬 문서와 같음 | 결정적 이름으로 옮김. 같은 결과 |
| I1 | 합집합 | 같은 페이지, 오프라인에서 A 3획·B 2획 | 5획 |
| I2 | 같은 id 수정 | A 올가미 이동@t1, B 색 변경@t2 | B의 상태(이동 없음). 같은 결과 |
| I3 | del 뒤 수정 | del@t1, 수정@t2 | 살아남(수정 내용) |
| I4 | 수정 뒤 del | 수정@t1, del@t2 | 삭제 |
| I5 | 지우기 취소 | iPad가 새 id로 다시 만듦 | 옛 id del, 새 id 생성. 손실 0 |
| I6 | 메아리 없음 | 원격 반영 직후 | 내보낼 객체 0개 |
| I7 | 이름 변경 | 앱 안에서 PDF 이름 변경 | 필기 내보내기 0개, `doc.upsert(name, rel_path)` 1개 |
| I8 | 회전 | 0/90/180/270, CropBox 오프셋 PDF | 객체 값이 바뀌지 않고 왕복 |
| I9 | 범위 밖 좌표 | x=1.02 | iPad에 1.0으로 저장, 되쓰지 않음 |
| I10 | clip·모르는 kind | `clip` 객체 | foreign에 보존, 그리지 않음, 나머지 정상 |
| I11 | 이미지 | asset 있음 / 늦게 도착 / sha 불일치 | relPath 채움 / 보류 후 반영 / 거부 |
| I12 | 1 MB 초과 | 세션 파일이 두 개로 나뉨 | 합집합 결과 동일 |
| I13 | 없는 쪽 | page가 PDF 쪽수보다 큼 | 숨김 보존, 쪽이 늘면 보임 |
| I14 | 자기 파일 삭제 | 파일 앱에서 자기 ink 파일을 지움 | 감사 후 같은 t로 다시 씀 |
| I15 | seq 되감기 | DB를 옛 백업으로 되돌림 | 새 파일 seq = 원격 최대 + 1 |
| I16 | 다른 기기로 복원 | DB를 새 iPad로 복원 | 새 device_id |
| N1 | 순차 수정 | A가 h0→h1, B가 h1을 받은 뒤 h1→h2 | h2, 사본 없음 |
| N2 | 동시 수정 | A h0→h1@t1, B h0→h2@t2 | 본문 h2, h1 사본 1개. 같은 id·이름 |
| N3 | 3기기 동시 | 세 기기가 각자 수정 | 승자 1, 사본 2 |
| N4 | 사본 중복 방지 | 사본이 이미 있거나 사용자가 지움 | 새로 만들지 않음 |
| N5 | 한 세션 여러 저장 | A h0→h1→h3(같은 파일), B h0→h2(t 더 큼) | 사본은 h3 하나(h1은 h3의 base) |
| N6 | 첨부 링크 | `assets/첨부-….png` 왕복 | 링크 복원, 양쪽 md_hash 동일 |
| N7 | 편집 중 | 저장하지 않은 초안이 있음 | 반영 보류, 저장 후 N2 규칙 |
| F1 | format | `{"format":3}` | 읽기·쓰기 중단, "앱 업데이트 필요" |
| F2 | 이상한 이름 | 점 파일, `.tmp`, 패턴 밖 이름 | 무시 |
| F3 | 손상 파일 | 잘린 gzip, 깨진 JSON | 그 파일만 건너뜀 |
| F4 | 경로 탈출 | `rel_path: "../x.pdf"` | 거부 |
| F5 | bandal.json 동시 생성 | iCloud 충돌 버전 | 해소 후 계속 |

---

## 4. UI

### 4.1 설정 > 동기화

설정에 "동기화" 카테고리를 새로 둔다. "계정"과 따로다.

```
동기화
  ( ) 끔   (●) iCloud   ( ) Google Drive
  상태           최신 상태 · 3분 전에 동기화                 [지금 동기화]
  iCloud         iCloud Drive › 반달
                 (또는) iCloud에 로그인되어 있지 않습니다    [설정 열기]
  Google Drive   name@gmail.com                              [연결 해제]
  이 기기 이름    iPad                                       (충돌 사본 이름에 쓰입니다)

  동기화되는 것: 과목, PDF, 필기, 텍스트 노트
  동기화되지 않는 것: 텍스트 하이라이트, 화이트보드, 그 밖의 파일, 연결 폴더 과목
  동기화 중인 문서는 페이지 순서를 바꾸거나 지울 수 없어요.
```

- 반달 로그인 상태와 관계없이 쓸 수 있다. 이 화면에는 로그인이나 구독 문구를 넣지 않는다.
- **상태 값**
  - 최신 상태
  - 동기화 중(남은 항목 수)
  - 업로드 대기 n개(iCloud 미업로드)
  - 일시 중지(사유)
  - 오류(사유, 다시 시도)
- **기기 이름**: iOS 16부터 `UIDevice.current.name`은 별도 엔타이틀먼트가 없으면 "iPad"만 돌려준다. 그래서 기본값은 "iPad"로 두고 사용자가 바꿀 수 있게 한다.
- **프로필**
  - 동기화 설정은 데이터 루트(프로필)마다 따로다.
  - iCloud 루트는 하나뿐이다. 그래서 한 번에 한 프로필만 iCloud에 연결할 수 있다.

### 4.2 초기 연결

제공자를 고르면 다음 순서로 진행한다.

1. 가용성을 확인한다(§4.4).
2. 루트를 읽는다.
   - 루트가 비어 있다(`bandal.json` 없음): 한 번 확인받고 전부 올린다. 진행률(PDF 총 크기)을 보여 준다.
   - format이 2보다 크다: 중단하고 "앱 업데이트 필요"를 띄운다.
   - 자료가 있다: 원격 상태를 끝까지 읽어 요약을 만든다. 이 단계에서는 아직 아무것도 쓰지 않는다. 그다음 시트를 띄운다.
3. 시트에서 방법을 고른다.

```
클라우드에 반달 자료가 있습니다
  클라우드: 과목 8 · 자료 107 (2.1 GB)      이 iPad: 과목 3 · 자료 52

  이름이 같은 과목 2개
    [✓] 물리학 ↔ 물리학
    [✓] 영어 ↔ 영어

  (●) 합치기 — 두 쪽 자료를 모두 유지합니다 (권장)
  ( ) 이 iPad 자료로 덮어쓰기 — 클라우드에만 있는 과목 6개, 자료 55개가 다른 기기에서도 삭제됩니다
  ( ) 클라우드 자료 가져오기 — 이 iPad 자료는 따로 보관하고 클라우드 자료로 시작합니다
                                                      [취소]  [계속]
```

- **합치기**
  - 합집합이다. 자동으로 지우는 것은 없다.
  - 합친 과목 안에서 sha256이 같은 PDF는 같은 문서로 보고 원격 id를 따른다. 로컬 id와는 매핑으로 연결한다.
  - 이름이 같은 과목은 체크한 것만 합치고, 원격 id를 따른다.
- **덮어쓰기**
  - 삭제될 개수를 보여 주고 한 번 더 확인받는다.
  - 원격에만 있는 과목·문서에 delete를 낸다. 합친 문서에서 원격에만 있는 필기에는 del을 낸다. 로컬 값은 전부 `clock+1`로 다시 내보낸다.
  - 노트는 md_base를 원격 승자로 둔다. 그래서 충돌 사본이 생기지 않는다.
  - foreign 객체(iPad가 판단할 수 없는 것)는 지우지 않는다.
  - 파일은 지우지 않고 tombstone만 쓴다.
- **가져오기**
  - 지금 데이터 루트는 그대로 둔다. 새 프로필로 전환한 뒤 그 프로필을 루트에 연결해 자료를 받는다.
  - 기존 프로필 기능(`DesktopProfileService`)을 쓴다. 이 기능은 옛 루트를 지우지 않는다.
  - 이 경로에서는 "먼저 백업" 요구를 건너뛴다. 옛 루트가 그대로 남기 때문이다.
  - 설정에 "이전 자료로 돌아가기"를 둔다. active-profile 포인터를 되돌리는 기능이다.

### 4.3 제공자 전환

- 새 제공자로 §4.2를 실행한다. 새 쪽이 비어 있으면 전부 올리고, 자료가 있으면 합치기 시트를 띄운다.
- 성공하면 옛 제공자를 해제한다. 감시를 멈추고 커서를 지운다. 옛 쪽의 파일은 지우지 않는다.
- 동시에 둘을 쓰지 않는다. 전환이 끝날 때까지 옛 제공자의 쓰기를 멈춘다. 실패하면 옛 제공자로 돌아간다.
- device_id와 seq는 이어서 쓴다.
- 해제했던 같은 루트에 다시 연결하면(루트 정체성이 같으면) 시트 없이 이어서 동기화한다.

### 4.4 iCloud 미로그인, 계정 변경, 루트 사라짐

- **켤 때 컨테이너 URL이 nil**
  - iCloud 항목 아래에 안내한다: "iCloud에 로그인하고 iCloud Drive를 켜야 합니다. 설정 › [이름] › iCloud에서 반달을 켜 주세요."
  - [설정 열기] 버튼을 둔다(`UIApplication.openSettingsURLString`). 이 버튼은 앱 설정 화면까지만 열 수 있다.
- **사용 중 로그아웃**: 일시 중지하고 사유를 보여 준다. 로컬 자료는 그대로다. 다시 로그인하면 자동으로 재개한다.
- **다른 Apple ID로 바뀜**(`ubiquityIdentityToken` 변경)
  - 일시 중지하고 묻는다: "다른 iCloud 계정입니다. 이 계정의 반달 폴더와 연결할까요?"
  - 예를 고르면 §4.2로 간다.
- **루트 사라짐**
  - 사용자가 파일 앱이나 Drive에서 폴더를 지웠거나, `bandal.json`의 정체성이 바뀐 경우다.
  - 일시 중지하고 묻는다: "클라우드의 반달 폴더가 없어졌습니다. 이 iPad 자료로 다시 만들까요?"
  - 예를 고르면 빈 루트처럼 전부 올린다.
  - 파일이 사라진 것을 삭제로 해석하지 않는다. 삭제는 tombstone으로만 일어난다.

### 4.5 마지막 동기화 시각

- `last_success_at`은 한 주기가 다음 두 조건을 모두 만족할 때 기록한다.
  - dirty가 비었다.
  - 원격 목록의 파일을 모두 처리했다.
- iCloud에서는 쓰기 성공과 업로드 완료가 다르다. 자기 파일 중 `NSMetadataUbiquitousItemIsUploadedKey == false`인 파일 수를 "업로드 대기 n개"로 따로 보여 준다.
- 상대 시각("3분 전")으로 보여 준다. 길게 누르면 절대 시각을 보여 준다.

### 4.6 페이지 재구성 제한

- **막는 것**
  - 동기화가 켜져 있으면 저장소가 `pdf:restructure`와 `pdf:restorePages`를 거부한다(`App/Native/Storage/NativePDFPageRepository.swift:7`). 오류 코드는 `SYNC_RESTRUCTURE_BLOCKED`다.
  - UI는 `pageCanRestructure`(`NativePDFWorkspace.swift:173`)를 false로 둔다. 페이지 패널에 "동기화 중인 문서는 페이지 순서를 바꾸거나 지울 수 없어요"를 보여 준다.
- **변경 제안 §12.2-2를 받아들이면**
  - 끝에 추가하는 것(`addPage(after: pageCount)`, `NativePDFWorkspace.swift:647`)만 허용한다.
  - 기존 쪽 번호가 그대로라서 필기가 어긋나지 않는다. pdf_sha256은 바뀌고, 새 PDF를 올린다.
- **`pdf:recoverPagesCopy`는 허용한다.** 새 자료를 만드는 작업이라 무료 한도 검사만 받는다.

---

## 5. iCloud 설정

### 5.1 entitlements (`App/Bandal.entitlements`에 추가)

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.app.bandal</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudDocuments</string></array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.app.bandal</string></array>
```

- 기존 `com.apple.developer.applesignin`은 유지한다.
- 키체인 access group은 추가하지 않는다. 기본 그룹으로 충분하다.
- 개발용과 App Store용 프로비저닝 프로파일을 iCloud가 포함되게 다시 만들어야 한다. 지금 프로파일(2026-10-26)에는 iCloud가 없다.

### 5.2 Info.plist (`App/Info.plist`)

```xml
<key>NSUbiquitousContainers</key>
<dict>
  <key>iCloud.app.bandal</key>
  <dict>
    <key>NSUbiquitousContainerIsDocumentScopePublic</key><true/>
    <key>NSUbiquitousContainerName</key><string>반달</string>
    <key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
  </dict>
</dict>
```

- 파일 앱에는 컨테이너의 `Documents/`만 "iCloud Drive › 반달" 폴더로 보인다.
- 알려진 함정이 있다. NSUbiquitousContainers를 바꾼 뒤 파일 앱에 폴더가 나타나려면 CFBundleVersion을 올려야 한다(E6에서 확인).
- `CFBundleURLTypes`에 Drive OAuth 콜백 스킴 `<iOS URL scheme>`을 추가한다(기존 `bandal` 옆). `ASWebAuthenticationSession`은 등록하지 않아도 콜백을 받지만, Google 안내에 맞춘다.
- 추가하지 않는 키: `UIBackgroundModes`, `BGTaskSchedulerPermittedIdentifiers`, `LSApplicationQueriesSchemes`.
- **같은 이름의 폴더가 두 곳 생긴다.** 파일 앱의 "나의 iPad › 반달"(앱 Documents, `UIFileSharingEnabled`)과 "iCloud Drive › 반달"(컨테이너)이다.
  - 권장: 그대로 두고, 설정 화면에 경로를 정확히 적는다(결정 필요).

### 5.3 Mac 데스크톱 경로

- 컨테이너 `iCloud.app.bandal`은 Mac에서 `~/Library/Mobile Documents/iCloud~app~bandal/Documents`다.
- 이 폴더는 iPad 또는 엔타이틀먼트가 있는 앱이 컨테이너에 처음 쓴 뒤에 생긴다(E1에서 확인).

---

## 6. 로그인 선택화와 계정 잠금 제거

### 6.1 바꾸는 것

| 대상 | 지금 | 바꾼 뒤 |
|---|---|---|
| `NativeLoginGate.requiresLogin` (`App/Native/NativeLoginGate.swift:11-15`) | 플래그를 끄면 바인딩 상태에 따라 앱 전체를 덮는다 | 게이트를 없앤다(항상 false) |
| `DesktopAccountService` 바인딩 | 시작할 때 영수증 확인(`:69-77`). 관련 함수: `auth:confirmProfile`(`:86`), `acceptLocalAccess`(`:270`), `containsExistingContent`(`:281`), `saveAccess`(`:297`), `checkBinding`(`:473`), `bind`(`:488`) | 모두 없앤다. 렌더 코드 호환을 위해 상태의 `localAccess`(`:104`)는 `allowed: true`, `requiresLogin: false`로 고정한다 |
| `restore()` (`:137`) | 영수증이 false면 세션을 복원하지 않는다 | 키체인에 세션이 있으면 복원한다 |
| `signOut()` | 영수증을 false로 바꿔 자료를 잠근다 | 세션만 지운다 |
| `syncIdentity()` (`:359`) | 바인딩을 확인한다 | 옛 동기화와 함께 비활성화한다(§7) |
| 설정 계정 카테고리 (`App/Native/NativeSettingsCatalog.swift:24`) | 숨김 | 계정 패널만 보인다. 구독 패널은 구독 PR에서 새로 만든다. 옛 동기화 패널과 프로필 패널은 계속 숨긴다 |
| 레일 계정 버튼 (`App/Native/NativeWorkspaceView.swift:564-573`) | 숨김 | 보인다. 마켓플레이스 버튼은 계속 숨긴다 |
| AI 진입점 | 로그인과 무관(BYOK) | 호스팅 AI를 넣으면 그 진입점에서만 로그인을 요구한다(§8.5) |

- `NativeReleaseFlags.isLocalOnly`(`App/Native/NativeReleaseFlags.swift:6`) 하나를 셋으로 나눈다.
  - `showsAccount = true`
  - `legacyCloudSync = false`: 옛 동기화와 서버 판정 구독
  - `showsMarketplace = false`
- 플래그 하나가 기능 하나에 대응해야 한다. 그래야 실수로 옛 동기화가 다시 켜지지 않는다.

### 6.2 기존 로그인 사용자는 업데이트 후 자료를 그대로 보는가

**그대로 본다.**

- **배포 사용자(1.0, 1.1)**: 계정 UI가 숨겨져 있어 로그인한 사용자가 없다. 바인딩 파일도 없다. 영향이 없다.
- **개발·TestFlight 기기**: 바인딩된 기기가 실제로 있다. 개발 iPad 백업(2026-10-28)에 `account-binding.json`(2026-10-17)과 `account-access.json`이 있다.
- **바인딩은 자료를 옮기지 않는다.**
  - 바인딩은 데이터 루트(`Documents/BandalDesktop` 또는 활성 프로필) 안에 놓인 파일일 뿐이다.
  - 그래서 게이트를 없애면 업데이트 직후에도 같은 자료가 그대로 보인다.
- **바인딩·영수증 파일은 지우지 않고 무시한다.**
  - PR을 되돌려도 옛 동작이 그대로 돌아온다.
  - 정리는 3단계 이후에 따로 한다.
- **로그인 상태도 유지된다.**
  - 키체인 세션(`sync.session`)은 그대로 유효하다.
  - issuer 검사는 §6.3 기준으로 통과한다.
- **프로필**
  - 프로필(`BandalProfile-<uuid>`)을 쓰던 기기는 그 프로필이 계속 활성이다.
  - "백업 후 새 프로필" 패널은 바인딩 때문에 있던 기능이므로 숨긴다. 코드는 남긴다. §4.2의 "가져오기"가 재사용한다.

### 6.3 auth 도메인 통일

- **실측**(2026-10-30, §13 E4)
  - `auth.bandal.io`는 `ukacrkcwiqafwpppshxb.supabase.co`의 CNAME이다.
  - `https://auth.bandal.io/auth/v1/.well-known/openid-configuration`은 200을 주고, `issuer`는 `https://ukacrkcwiqafwpppshxb.supabase.co/auth/v1`이다. supabase.co 주소의 같은 문서도 같은 값이다.
  - 데스크톱 1단계 실측에 따르면 Google OAuth 콜백도 이미 `https://auth.bandal.io/auth/v1/callback`이다.
- **결론**
  - 접속 주소는 auth.bandal.io로 바꾼다. 하지만 토큰의 `iss`는 supabase.co 값 그대로다.
  - 지금 검사(`DesktopAccountService.swift:462`, `iss == 접속 주소 + "/auth/v1"`)를 그대로 두면 주소만 바꿨을 때 모든 로그인을 거부한다.
- **변경**
  - `App/Resources/Configuration.plist`(git이 무시하는 파일)
    - `sync.url = https://auth.bandal.io`
    - 새 키 `sync.issuer = https://ukacrkcwiqafwpppshxb.supabase.co/auth/v1`
  - 검사는 `iss == sync.issuer`로 바꾼다. 키가 없으면 지금처럼 `url + "/auth/v1"`을 쓴다.
  - 이제 supabase.co는 issuer 비교 문자열로만 남고 호출에는 쓰이지 않는다.
  - Edge Function(`account-delete`)도 같은 base(`https://auth.bandal.io/functions/v1/…`)로 간다. 커스텀 도메인은 프로젝트 API 전체에 적용된다.
- **기기에 저장된 옛 주소 정리**
  - 숨은 "서버 설정"(`native:configureAccount`, `App/Native/NativePlatformServices.swift:164`)으로 `sync.url`을 저장한 기기가 있다. 저장된 값은 등록 기본값을 가린다.
  - 시작할 때 저장된 값이 옛 supabase.co 주소면 지운다.
  - 이 숨은 설정은 issuer까지 받아야 하므로 DEBUG 빌드에만 남긴다.
- PR1 수동 테스트에서 실제 access token을 디코드해 `iss`를 한 번 더 확인한다(E4b).

### 6.4 Kakao 제거

- **코드**
  - `signIn`의 허용 목록(`DesktopAccountService.swift:167`)에서 `kakao`를 뺀다.
  - 로그인 화면과 설정의 버튼·문구를 지운다(`App/Native/NativeLoginGate.swift`, `App/Native/NativeSettingsWorkspace.swift`).
  - 테스트를 정리한다(`Tests/BandalTests/DesktopAccountTests.swift`).
- **서버**: Supabase의 Kakao 프로바이더는 이미 꺼져 있다. 데스크톱 1단계 실측에서 `provider is not enabled`를 받았다. 그러니 iPad의 Kakao 버튼은 지금도 동작하지 않는 상태였다.
- **Kakao로만 가입한 계정**: 개발 계정뿐이다. Apple이나 Google을 연결해 두지 않았다면 로그인할 수 없게 된다. 로컬 자료는 이제 로그인과 무관하므로 영향이 없다.

### 6.5 Google

- **반달 로그인**: 지금의 웹 PKCE 흐름(`/auth/v1/authorize?provider=google`)을 auth.bandal.io 주소로 그대로 쓴다. 서버 설정(콜백)은 이미 맞다. 새 코드가 필요 없다.
- **iOS 클라이언트**(`<iOS Client ID>`): Drive 동기화 인증에 쓴다(§1.4).
- **대안: iOS 클라이언트로 네이티브 로그인**
  - iOS 클라이언트로 id_token을 받아 Apple과 같은 `grant_type=id_token` 경로로 로그인하는 방법이다.
  - 사용자에게 보이는 차이는 동의 화면 도메인이 accounts.google.com이 되는 정도다.
  - 대신 Supabase Google 프로바이더의 Client IDs에 iOS 클라이언트를 추가하고 nonce를 처리해야 한다.
  - 권장하지 않는다(결정 필요).
- **Apple**: 바뀌는 것이 없다. 네이티브 id_token을 auth.bandal.io로 보낸다.

---

## 7. 기존 CommonSync 중단

### 7.1 방법 (PR1)

1. `DesktopSyncService`를 만들지 않는다(`NativePlatformServices.swift:107`). 그러면 `sync?.start()`(`:134`)가 15초 타이머와 포그라운드 옵저버를 등록하지 않는다.
2. `sync:*` 채널은 "이 버전에서는 사용할 수 없습니다"를 돌려준다. 오류 코드는 `LEGACY_SYNC_DISABLED`다.
3. 서버 판정 구독 `DesktopBillingService`도 만들지 않는다(`:115`).
   - 로그인이 보이게 되면 `Transaction.updates` 리스너가 Edge Function(`verify`)으로 거래를 보낼 수 있기 때문이다.
   - 상품 ID 문자열 `app.bandal.ipad.sync.*`(`App/Desktop/DesktopBillingService.swift:60`)은 지운다. 서비스 코드는 플래그 뒤에 남긴다.
4. 옛 동기화 UI(동기화 패널, 구독 패널)는 계속 숨긴다.
5. 코드는 `legacyCloudSync = false` 뒤에 남긴다. 삭제는 3단계 이후에 따로 정한다.

### 7.2 영향 범위

| 대상 | 영향 |
|---|---|
| 배포 사용자 | 없다. 지금도 `syncEnabled != "true"`라서 아무것도 올리지 않았다 |
| 개발 기기 | 업로드가 멈춘다. `CommonSync/` 큐와 `ipad_sync_*` 테이블은 지우지 않고 남는다. 서버에 이미 올라간 자료도 남는다 |
| 데스크톱 | 데스크톱의 옛 iPad 동기화(Python 브리지, `bandal_push`)는 별개다. iPad가 멈춰도 데스크톱 쪽 업로드는 계속된다. 데스크톱 철거는 데스크톱 설계안에서 다룬다 |

### 7.3 서버 쪽 (결정 필요)

- 클라이언트만 막으면 옛 개발·TestFlight 빌드와 데스크톱은 계속 올릴 수 있다.
- "Supabase에 사용자 자료를 올리지 않는다"를 서버에서 보장하려면 다음 권한을 회수해야 한다. 시점은 데스크톱 철거와 함께 정한다.
  - `bandal_push` 실행 권한
  - Storage `bandal-assets` 쓰기 정책
- 이미 올라간 자료를 보존할지, 삭제할지, 사용자에게 내려받기를 제공할지도 같이 정한다.

---

## 8. 구독 (Bandal Pro)

### 8.1 StoreKit 2 구현

- **상품 ID**: `app.bandal.ipad.pro.monthly`, `app.bandal.ipad.pro.yearly`를 그대로 확정하는 것을 권장한다.
  - 구독 그룹은 "Bandal Pro"다.
  - 두 상품은 같은 레벨에 둔다. 같은 서비스이고 기간만 다르기 때문이다. 서로 바꾸면 다음 갱신일부터 적용된다.
- **새 파일** `App/Services/BandalPro.swift`(골격):

```swift
@MainActor @Observable final class BandalPro {
    static let productIDs: Set<String> = ["app.bandal.ipad.pro.monthly", "app.bandal.ipad.pro.yearly"]
    private(set) var isActive = false

    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil { active = true }
        }
        isActive = active
    }
    func listen() -> Task<Void, Never> {
        Task { for await update in Transaction.updates {
            if case .verified(let t) = update { await t.finish() }
            await refresh()
        } }
    }
}
```

- **판정**
  - 기기에서만 판정한다. 거래를 서버로 보내지 않는다.
  - `currentEntitlements`는 서명된 캐시라서 오프라인에서도 동작한다. 만료와 환불(revocation)은 StoreKit이 반영한다.
- **앱 시작**: `listen()`과 `refresh()`를 부른다. 미완료 거래는 `Transaction.unfinished`를 돌며 finish한다.
- **복원**: `AppStore.sync()`. 로그인과 무관하다.
- **appAccountToken**
  - 로그인 상태면 `UUID(uuidString: session.user.id)`를 구매 옵션에 넣는다. 로그아웃 상태면 넣지 않는다. 어느 쪽이든 구매와 복원은 된다.
  - v2에서 App Store Server Notifications로 거래를 사용자와 묶을 때 이 값을 쓴다.
- **테스트**: `Products.storekit`(StoreKit 구성 파일)과 `SKTestSession`으로 구매, 만료, 환불, 복원을 단위 테스트한다.
- **기존 서버 판정 서비스**: `DesktopBillingService`는 PR1에서 생성을 멈추고, 이 PR에서 `BandalPro`로 대체한다.

### 8.2 한도 체크 지점

- 검사는 한 곳에서 한다. `DesktopRuntime`의 채널 디스패치 앞에서 `FreeTier.check(channel, request)`를 부른다. 저장소 함수 깊숙이 넣지 않는다.
- 동기화가 원격 자료를 만들 때는 이 채널을 거치지 않는다. 그래서 받은 자료는 자연스럽게 검사에서 빠진다.

| 채널 | 무엇을 만드나 | 막는 조건 |
|---|---|---|
| `courses:create` | 새 과목 | 이 iPad에서 만든 과목(살아 있는 것)이 1개 이상 |
| `courses:addFromFolder` | 연결 폴더 과목 | 같음 |
| `materials:import` | 파일 가져오기(여러 개 가능) | 이 iPad에서 만든 자료 수 + 가져올 PDF·md 수 > 10 |
| `materials:importShared` | 공유로 들어온 파일 | 같음 |
| `materials:duplicate` | 복제 | 같음 |
| `notes:create` | 텍스트 노트 | 같음 |
| `pdfNotes:create` | 손글씨 노트 | 같음 |
| `pdf:recoverPagesCopy` | 페이지 사본 | 같음 |

- 한도를 넘으면 `DesktopRuntimeError(code: "PRO_REQUIRED")`를 던진다. UI는 이 코드를 받으면 페이월을 연다.
- **"자료"로 세는 것**: PDF와 md만 센다. 동기화 대상과 같은 범위다. 첨부 이미지(`assets/`)와 기타 파일은 세지 않는다(결정 필요).
- **파일 앱 경로는 막지 않는다.** 파일 앱으로 과목 폴더에 직접 넣은 파일은 5초 스캔이 색인한다. 막으면 사용자의 파일이 앱에서 숨겨진다. 알려진 우회로로 둔다.
- **여러 개 가져오기**: 한도를 넘으면 전체를 막고 "무료로 n개 더 추가할 수 있어요"를 보여 준다. 일부만 가져오지 않는다(결정 필요).

### 8.3 "이 iPad에서 만든 것"과 기존 사용자 보호

- **세는 대상**: `origin = 'local'`이면서 살아 있는 과목과 문서다. `origin`은 §1.9 매핑 테이블에 있다. 동기화로 생긴 것은 `remote`다.
- **기존 사용자**
  - 업그레이드할 때 기존 자료는 전부 `local`이 된다.
  - 이미 한도를 넘은 사용자도 잠기거나 지워지는 것이 없다. 새로 만들기만 막힌다. 정책 그대로다.
- **동기화로 받은 과목에 새 자료를 만드는 것**: "iPad에서 새로 만든 자료"로 센다(권장, 결정 필요). 받은 자료를 보고 고치는 것은 언제나 된다.
- **기기 복원, 새 iPad**: 매핑 테이블이 DB와 함께 복원되므로 그대로 `local`이다.
- **구독이 끝나면**: 다시 새로 만들기만 막힌다. 만든 자료는 그대로다.

### 8.4 페이월

SwiftUI `SubscriptionStoreView(productIDs:)`를 쓴다. iOS 17부터 쓸 수 있고 배포 대상은 iOS 18이다. 가격, 기간, 구독 버튼, 자동 갱신 고지는 시스템이 그린다.

```swift
SubscriptionStoreView(productIDs: BandalPro.productIDs) { BandalProMarketing() }  // 포함 내용과 한도
    .storeButton(.visible, for: .restorePurchases)
    .storeButton(.visible, for: .policies)
    .subscriptionStorePolicyDestination(url: URL(string: "https://bandal.io/privacy")!, for: .privacyPolicy)
    .subscriptionStorePolicyDestination(url: eulaURL, for: .termsOfService)
    .inAppPurchaseOptions { _ in accountUUID.map { [.appAccountToken($0)] } ?? [] }
```

- **마케팅 영역 문구.** 동기화와 외부 결제는 언급하지 않는다.
  - Bandal Pro: "과목과 자료를 개수 제한 없이 만들 수 있어요. AI를 매달 <Pro 한도>회 쓸 수 있어요."
  - 무료: "이 iPad에서 과목 1개, 자료 10개까지 만들 수 있어요. 받은 자료는 개수와 관계없이 보고 고칠 수 있어요. AI는 매달 <무료 체험 횟수>회 쓸 수 있어요(로그인 필요)."
- **구독 관리**: 설정 › 구독에 둔다. `manageSubscriptionsSheet`를 쓴다. 기존 `AppStore.showManageSubscriptions`를 써도 된다. 복원 버튼도 같은 곳에 둔다.
- **EULA**
  - Apple 표준 EULA(`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`)와 자체 약관 URL 중 하나를 쓴다(결정 필요).
  - App Store 설명에도 링크를 넣는다(§11).
- **페이월이 열리는 곳**
  - 한도 초과(`PRO_REQUIRED`)
  - 설정 › 구독
  - 무료 사용자의 AI 한도 초과

### 8.5 AI 한도와 지금의 BYOK

- **현황**
  - iPad AI는 사용자가 등록한 API 키로 OpenAI, Anthropic, Google을 직접 부른다(키체인 `ai.<provider>`, `DesktopAIService.swift:5-6, 65`).
  - 반달 서버를 거치지 않고 로그인도 필요 없다. 1.0부터 출시된 기능이다.
- **정책과의 관계**: "로그인 필수, 서버가 사용자별 월 한도"는 반달 키로 호출하는 호스팅 AI가 있어야 성립한다. 그런 서버는 아직 없다.
- **제안 구조(v1)**
  - 클라이언트: 새 제공자 "반달 AI"를 추가한다. 요청은 다음과 같다.
    - `POST https://auth.bandal.io/functions/v1/ai`
    - `Authorization: Bearer <access token>`
    - 헤더 `x-bandal-plan: pro|free`: 클라이언트가 판정한 값
    - 헤더 `x-bandal-entitlement: <최신 구독 거래 JWS>`: 있을 때만
  - 서버
    - JWT를 검증하고 `ai_usage(user_id, month, count)`를 1 늘린다.
    - plan별 한도를 넘으면 429와 다음 본문을 돌려준다: `{"code":"ai-quota-exceeded","limit":N,"used":N,"resetsAt":"…"}`
  - v1 서버는 정책대로 plan 헤더를 믿는다.
  - JWS를 함께 받아 두는 이유: v2에서 클라이언트를 바꾸지 않고 서버만 바꿀 수 있다. 서명 검증과 Server Notifications 기반 판정으로 옮기면 된다. 이때 appAccountToken(= user id)이 거래와 사용자를 잇는다.
  - 429를 받으면 무료 사용자에게는 페이월을, Pro 사용자에게는 "이번 달 한도를 다 썼어요(n일에 초기화)"를 보여 준다.
- **결정 필요**
  - BYOK를 그대로 둘지. 권장은 둔다. 로그인과 한도가 없고 비용은 사용자가 내며 기존 사용자를 보호한다.
  - 호스팅 AI 서버의 일정
  - 1회의 정의(권장: 요청 1건)
  - 쓸 모델

---

## 9. PR 분할과 순서

| 순서 | PR | 내용 | 의존 | 검증 |
|---|---|---|---|---|
| 1 | (a) 로그인 선택화 | CommonSync와 서버 판정 구독 생성 중단, Kakao 제거, auth.bandal.io와 issuer 설정, 게이트·바인딩 제거, 플래그 분리, 계정 카테고리 표시 | 없음 | 단위 테스트: 바인딩 파일이 있어도 게이트가 없다, Kakao 거부, issuer 검사, `sync:*` 비활성. UI 테스트: 바인딩이 맞지 않는 fixture로 실행해도 라이브러리가 보인다. 수동: 실기기 Apple·Google 로그인, 토큰 iss 확인(E4b) |
| 2 | (b) 동기화 식별자 | cloud_sync_* 테이블, device_id·seq·clock, 과목·md id 부여, PDF id = 바인딩, 재매칭, repoint 연동, origin | 1 | I15·I16, 재매칭, 앱 안 이름 변경 후 id 유지, 업그레이드를 두 번 돌려도 결과 같음 |
| 3 | (c) Bandal Pro | StoreKit 2 로컬 판정, 상품, 한도 검사, 페이월, 설정 › 구독, `Products.storekit` | 2(origin) | SKTestSession으로 구매·만료·환불·복원, §8.2 표. UI 테스트: 한도 초과 시 페이월 |
| 4 | (d) SyncAdapter·머지 | 내보내기·가져오기, SyncMerge, FolderProvider, gzip, sync-fixtures 적합성 테스트 | 2 | §3.5 전부와 fixtures |
| 5 | (e) ICloudProvider | entitlements, NSUbiquitousContainers, 감시·조정·내려받기, 가용성과 계정 변경 처리 | 4, 프로파일 재발급 | 실기기 2대와 Mac(E1, E2, E5, E6) |
| 6 | (f) 동기화 설정 UI | 설정 › 동기화, 초기 연결 시트, 제공자 전환, 상태 표시, 재구성 제한, 열린 문서 다시 읽기 | 5 | FolderProvider를 주입한 UI 테스트, 수동 체크리스트 |
| 7 | (g) DriveProvider | Google OAuth(iOS 클라이언트), 목록·변경·업로드·재개, 15초 제한 | 4, 6 | 실계정 수동(E3). 단위 테스트: 같은 이름 폴더 여러 개, generateIds 재시도 |
| 별도 | (h) 호스팅 AI | Edge Function `ai`, `ai_usage`, 클라이언트 제공자 | 1, 3 | 결정 후 |

- **구독(3)을 동기화(4–7)보다 앞에 둔 이유**
  - 둘은 서로 독립이고, 구독을 먼저 하면 출시할 수 있는 단위가 먼저 나온다.
  - 동기화가 출시되기 전에는 `remote` 자료가 없다. 그래서 한도는 전체 개수와 같다.
- **출시 묶음 제안**(결정 필요)

  | 버전 | 포함 |
  |---|---|
  | 1.2 | (a), (b), (c). (h)는 결정하면 포함 |
  | 1.3 | (d)–(f), iCloud |
  | 1.4 | (g), Drive |

- 각 PR은 기본값이 꺼진 플래그 뒤에서 합칠 수 있다. 동기화 UI는 (f)에서 켠다.

---

## 10. sync-fixtures 검증 계획

- **원본과 사본**
  - 원본은 데스크톱 저장소의 `sync-fixtures/`다. 초안은 데스크톱 팀이 쓴다.
  - iPad는 특정 커밋의 사본을 `Tests/Fixtures/sync-fixtures/`에 두고, 출처 커밋을 `SOURCE` 파일에 적는다.
  - 갱신은 `Scripts/update-sync-fixtures.sh <commit>` 스크립트 하나로 한다.
  - submodule 대신 사본을 쓰는 이유: 오프라인 빌드와 CI가 단순해진다(결정 필요).
- **케이스 구조**

```
sync-fixtures/<case>/
  root/            동기화 루트 트리(스펙 v2 그대로)
  local.json       (선택) 시작할 때의 로컬 상태. 초기 연결·내보내기 케이스용
  expected.json    정규화한 기대 상태
```

- **expected.json 형식**: 두 파서의 출력을 비교하기 위한 정규화 형식이다.

```json
{"courses": {"<id>": {"name": "물리학", "sort": 0, "color": "blue", "archived": false, "alive": true}},
 "docs": {"<id>": {"course_id": "<id>", "type": "pdf", "name": "1주차", "rel_path": "1주차.pdf",
                   "pdf_sha256": "…", "alive": true}},
 "ink": {"<doc>": {"3": {"<object id>": {"t": 1793268000123, "del": false, "sha256": "<정규 JSON 해시>"}}}},
 "notes": {"<doc>": {"md_hash": "…"}},
 "conflict_copies": [{"id": "<uuidv5>", "of": "<doc>", "md_hash": "…", "name": "… (충돌 사본 iPad).md"}],
 "ignored": ["ink/<doc>/3/bad.json.gz"],
 "errors": []}
```

- **객체 해시**: 정규 JSON(키 정렬, 공백 없음)의 SHA-256이다. 정규 JSON 규칙도 fixture로 고정한다.
- **iPad 테스트** `SyncFixtureConformanceTests`
  - 가져오기: 케이스마다 임시 DB와 `FolderProvider(root)`를 만들고 가져온 뒤, 정규화해 `expected.json`과 비교한다.
  - 내보내기: `local.json`을 심고 내보낸다. 내보낸 트리를 다른 DB로 다시 가져와 상태가 같은지 확인한다.
  - 핵심은 교차 케이스다. 데스크톱이 만든 트리를 iPad가 읽고, iPad가 내보낸 트리를 데스크톱 기대값으로 검증한다.
- **렌더 케이스**(`render/`)
  - 획 입력 몇 개와 그 V5 외곽선 기대값을 둔다. 허용오차는 페이지 폭의 1e-6이다.
  - 두 구현이 같은 굵기를 내는지 고정한다. 1.6배 문제가 여기서 확인된다.
  - 기대값은 iPad 구현으로 만들고 데스크톱이 맞춘다. iPad 엔진을 바꾸지 않는다는 원칙 때문이다(결정 필요).
- **iPad 팀이 요청할 최소 케이스**: §3.5의 M1–M9, I1–I16 중 파일로 표현되는 것, N1–N7, F1–F5.
- 두 저장소의 CI 모두에서 돌린다. 포맷을 바꾸는 PR은 fixture도 함께 고친다(스펙 규칙).

---

## 11. 사람이 콘솔에서 할 일

### Apple Developer

1. App ID `app.bandal.ipad`에 iCloud(iCloud Documents)와 컨테이너 `iCloud.app.bandal`이 연결돼 있는지 확인한다. 연결은 완료됐다고 보고받았다.
2. 프로비저닝 프로파일을 다시 만든다.
   - 대상: Development, App Store("app.bandal.ipad AppStore", `fastlane profile`/sigh)
   - 새 프로파일에 `icloud-container-identifiers`가 들어 있는지 확인한다.

### App Store Connect

1. **유료 앱 계약.** Paid Applications Agreement를 체결하고 은행·세금 정보를 넣는다. 이것이 없으면 구독을 팔 수 없다. 2026-10-18 출시 준비 기록에는 미체결로 남아 있다. 지금 상태는 ASC에서 확인해야 한다.
2. **구독 그룹.** 참조 이름은 `Bandal Pro`다. 그룹 표시 이름은 ko `반달 Pro`, en `Bandal Pro`다.
3. **상품 2개**

   | 항목 | 월간 | 연간 |
   |---|---|---|
   | Product ID | `app.bandal.ipad.pro.monthly` | `app.bandal.ipad.pro.yearly` |
   | 참조 이름 | Bandal Pro Monthly | Bandal Pro Yearly |
   | 기간 | 1개월 | 1년 |
   | 레벨 | 1 | 1 |
   | 표시 이름 ko / en | 반달 Pro 월간 / Bandal Pro Monthly | 반달 Pro 연간 / Bandal Pro Yearly |
   | 설명 ko | 과목·자료 무제한, AI 월 <Pro 한도>회 | 같음 |
   | 설명 en | Unlimited subjects & materials, more AI | 같음 |
   | 가격 | 결정 필요 | 결정 필요 |
   | 도입 혜택(무료 체험) | 결정 필요 | 결정 필요 |
   | 가족 공유 | 결정 필요(기본 끔) | 같음 |
   | 판매 지역 | 앱과 같게(EU 27개국 제외 148개) | 같음 |
   | 심사 자료 | 페이월 스크린샷, 심사 메모(무료 한도를 재현하는 방법) | 같음 |

   설명에는 동기화와 외부 결제를 언급하지 않는다. ASC 글자 수 제한이 있으므로 짧게 쓴다.
4. **약관 링크.** 앱 설명(또는 사용권 계약 칸)에 이용약관(EULA)과 개인정보 처리방침 링크를 넣는다.
5. **앱 개인정보(App Privacy) 라벨.** 지금은 "데이터 수집 안 함"이다. 로그인이 보이게 되면 바꿔야 한다.
   - 추가할 항목: 이메일 주소, 사용자 ID(앱 기능, 사용자에 연결)
   - 호스팅 AI를 넣으면 처리 방식에 따라 더한다.
   - iCloud·Drive 자료는 사용자 저장소에만 있으므로 개발자 수집이 아니다.
   - 개인정보 처리방침(bandal.io/privacy)도 같이 고친다. Google API 사용자 데이터 정책 공개 문구를 포함해야 한다.
6. **App Store Server Notifications URL.** v1에서는 비워 둔다. v2에서 설정한다.

### Google Cloud (Supabase Google 로그인과 같은 프로젝트)

1. Google Drive API를 사용 설정한다.
2. OAuth 동의 화면을 설정한다.

   | 항목 | 값 |
   |---|---|
   | 앱 이름 | `반달` |
   | 지원 이메일, 로고 | 입력 |
   | 홈페이지 | `https://bandal.io` |
   | 개인정보 처리방침 | `https://bandal.io/privacy` |
   | 약관 | 약관 URL |
   | 승인된 도메인 | `bandal.io` |
   | 스코프 | `openid`, `email`, `profile`, `https://www.googleapis.com/auth/drive.file` |

3. 게시 상태를 "프로덕션"으로 바꾸고 브랜드 확인(앱 이름·로고 표시)을 신청한다. "테스트" 상태에서는 refresh token이 7일 뒤 만료된다. 그러면 Drive 동기화가 주기적으로 끊긴다.
4. iOS OAuth 클라이언트를 확인한다.
   - 번들 ID `app.bandal.ipad`, 팀 ID `VUZ7Z98BW3`
   - 결과값 `<iOS Client ID>`와 URL scheme `<iOS URL scheme>`은 만들었다고 보고받았다. 실제 값을 전달해 주어야 한다.
5. 데스크톱의 Drive용 OAuth 클라이언트도 **같은 프로젝트**에 둔다. drive.file 접근은 앱(프로젝트) 단위로 묶이는 것으로 보인다. 프로젝트가 다르면 서로의 파일을 볼 수 없을 수 있다(E3에서 실측).
6. 웹 클라이언트(Supabase Google 프로바이더)의 승인된 리디렉션 URI에 `https://auth.bandal.io/auth/v1/callback`이 있는지 확인한다. 이미 동작 중이다.
7. Drive API 사용량 알림을 설정한다. 계산은 데스크톱 1단계 §10을 참조한다.

### Supabase

1. 커스텀 도메인 `auth.bandal.io`: 2026-10-30에 활성 상태임을 확인했다. 할 일이 없다.
2. Auth › Providers: Apple(Client IDs에 `app.bandal.ipad`)과 Google을 확인한다. Kakao는 비활성으로 유지한다.
3. Auth › URL Configuration: Redirect URLs에 `bandal://auth/callback`이 있는지 확인한다.
4. 옛 동기화 차단(결정한 뒤): `bandal_push` 실행 권한을 회수하고, Storage `bandal-assets`의 insert·update 정책을 없앤다. 이미 올라간 자료의 처리도 함께 한다.
5. 호스팅 AI(결정한 뒤): Edge Function `ai`, 테이블 `ai_usage`, 제공자 API 키 시크릿을 만든다.

### 데스크톱 팀과 합의할 것

§12.1의 키·타입 초안, §12.2의 변경 제안, fixture 원본 위치(§10).

---

## 12. 공통 스펙 v2: 합의 초안과 변경 제안

### 12.1 스펙이 설계안에 맡긴 것 (합의 초안)

1. **필기 객체 키·타입**: §2.3 표. 핵심은 세 가지다.
   - `data`와 `style`을 행 그대로 둔다.
   - `created`를 더한다.
   - 묘비는 최소형만 있어도 된다.
2. **color**: 이름 토큰 7종만 쓴다. hex는 쓰지 않는다. 두 앱 모두 토큰만 저장한다.
3. **숫자 정밀도**: 반올림 여부(§2.3, 결정 필요).
4. **이미지**: `data.image.relPath`를 `sha256`과 `ext`로 바꾼다.
5. **md 첨부 링크와 md_hash**: 링크는 `../../assets/<sha256>.<ext>`다. md_hash는 정규화한 노트 바이트의 SHA-256(소문자 hex)이다.
6. **동률 규칙**: device_id가 큰 쪽이 이긴다. 필기에도 적용한다.
7. **충돌 사본**: 결정적 id(UUIDv5 네임스페이스 값)와 이름 형식.
8. **이름 규칙**: 읽는 쪽은 패턴 밖의 이름을 모두 무시한다. 쓰는 쪽은 임시 파일을 루트 밖에서 만든다.
9. **정규 JSON**(해시용): 키 정렬, 공백 없음, 숫자 표기 규칙.
10. **기기 이름**: `devices/<id>.json`의 name은 사용자가 바꿀 수 있다. iOS의 기본값은 "iPad"다.

### 12.2 변경 제안 (스펙 문장을 바꿔야 하는 것)

1. **노트 이벤트에 `md_base`를 추가한다.**
   - md 문서의 `doc.upsert`에 "이 수정이 출발한 md_hash"를 넣는다.
   - 근거는 §3.4다. 이 필드가 없으면 "양쪽이 각자 수정하면 충돌 사본" 규칙을 손실 없이 판정할 수 없다.
2. **끝에 페이지를 추가하는 것은 재구성 금지의 예외로 한다.**
   - 기존 쪽 번호가 바뀌지 않으므로 필기가 어긋나지 않는다.
   - 손글씨 노트의 "페이지 추가"가 재구성 경로라서, 막으면 동기화 중인 노트를 늘릴 수 없다.
   - 한계: 두 기기가 동시에 페이지를 추가하면 pdf_sha256 LWW로 한쪽 PDF가 이긴다. 진 쪽에서 새 페이지에 쓴 필기는 그 쪽이 없으면 숨겨진다. 지워지지는 않는다.
3. **동률 규칙 문장을 명확히 한다.** "t가 같으면 device_id를 문자열로 비교해 큰 쪽이 이긴다. 필기 객체에도 적용한다."
4. **노트 첨부 규칙을 넣는다.** "노트의 첨부는 assets/에 두고, 본문은 `../../assets/<sha256>.<ext>`로 참조한다."
5. **읽기 무시 규칙을 넣는다.** "패턴에 맞지 않는 파일과 점으로 시작하는 이름은 무시한다. 임시 파일은 루트 밖에서 만든다."

---

## 13. 검증 실험

### 한 것

**E0. 실제 iPad 데이터로 v2 필기 파일 크기 측정**

- **방법**
  - 개발 iPad 백업(`~/dev/bandal-iPad-backups/2026-10-28-materials-browser/after`)의 bandal.db를 스크래치 공간에 복사해 읽기 전용으로 열었다.
  - (문서, 페이지)마다 §2.3 형태의 객체 배열을 만들어 gzip(레벨 6)했다. 이미지 relPath는 64자 해시로 바꿨다.
  - 집계 숫자만 기록했다.
- **자료 규모**
  - 과목 3개, PDF 47개(바인딩 37개), md 노트 5개, 과목 폴더 파일 92 MB
  - 필기가 있는 문서 17개, 페이지 44개
  - 살아 있는 객체 19,869개(ink 19,810, line 58, ellipse 1), 묘비 6,949개, 샘플 944,106개
  - 가장 빽빽한 페이지: 객체 1,695개, 샘플 80,141개

| 페이지 파일 gzip | 원래 정밀도 | 반올림(x·y 5자리, p 3자리, t·tilt 1자리) |
|---|---|---|
| 중앙값 | 386 KB | 144 KB |
| p90 | 1,524 KB | 566 KB |
| 최대 | 2,479 KB | 864 KB |
| 1 MB 넘는 페이지 | 11 / 44 | 0 / 44 |
| 256 KB 넘는 페이지 | 23 / 44 | 18 / 44 |
| 전체(gzip) | 25.9 MB | 9.6 MB |
| 샘플당 | 28.8 B | 10.6 B |

- 1단계 합성 추정치(샘플당 57 B)보다 작다. 객체 하나의 평균 샘플 수는 47.5개로, §1.8의 업로드량 추정에 이 값을 썼다.
- **참고(범위 밖)**: 이 DB는 1.8 GB다. 대부분이 `native_pdf_page_history`(1.3 GB), `drawing_create_receipts`(212 MB), `pdf_drawings`(206 MB)다. 동기화 대상은 아니다. 다만 Documents 안에 있으므로 파일 앱과 기기 백업에 그대로 잡힌다.

**E4. auth.bandal.io의 issuer**

- 확인 방법: `dig`과 `curl`로 두 주소의 `/auth/v1/.well-known/openid-configuration`을 조회했다(부록 A).
- 결과: 두 주소 모두 `issuer = https://ukacrkcwiqafwpppshxb.supabase.co/auth/v1`, `jwks_uri`도 supabase.co였다.
- 실제 access token의 iss는 PR1에서 확인한다(E4b).

### 3단계 초반에 할 것 (실험 브랜치에서, PR 없음)

| ID | 무엇을 | 왜 |
|---|---|---|
| E1 | 엔타이틀먼트 없는 Electron이 Mac 컨테이너 폴더에 쓴 파일이 iPad에 도착하는지, 반대 방향도 | 데스크톱 iCloud 경로의 전제 |
| E2 | NSMetadataQuery의 지연과 누락(iPad 2대) | 동기화 지연 기대치 |
| E3 | drive.file: 같은 프로젝트의 다른 클라이언트(데스크톱과 iOS)가 서로의 파일을 보는지 | Drive 공유의 전제 |
| E4b | 실제 access token의 iss | §6.3 확정 |
| E5 | 컨테이너와 과목 폴더 사이 복사가 APFS 클론인지 | 저장 공간이 두 배가 되는지 |
| E6 | 파일 앱에 "반달" 폴더가 나타나는 조건(CFBundleVersion) | §5.2 |
| E7 | 1시간 필기 시 세션 파일 업로드량(iCloud, Drive) | §1.8 추정 검증 |

- 필요한 것: iCloud가 포함된 프로파일, iPad 2대(또는 iPad와 Mac), 테스트용 Apple ID와 Google 계정.

---

## 14. 결정 필요

권장안을 함께 적었다. 권장대로라면 "권장대로"라고만 답하면 된다.

1. **필기 숫자 정밀도**
   - 권장: 반올림(x·y 소수 5자리, p 3자리, t·tilt 1자리). 파일이 2.7배 작아지고 1 MB를 넘는 페이지가 없어진다(§13 E0).
   - 대안: 원래 정밀도(스펙의 "그대로"를 글자 그대로 따름).
2. **`md_base` 추가**(§12.2-1): 권장 수용. 노트 손실 0의 조건이다.
3. **끝에 페이지 추가 예외**(§12.2-2): 권장 수용. 받아들이지 않으면 동기화 중인 노트에 페이지를 추가할 수 없다.
4. **v1 동기화 범위에서 빼는 것**: 텍스트 하이라이트, 화이트보드, 기타 파일, PDF 페이지 노트 링크, 과목 그룹.
   - 권장: 모두 뺀다. 하이라이트는 v1.1에서 다룬다.
5. **연결 폴더 과목**: 권장 제외.
6. **원격 삭제 처리**: 권장은 `SyncTrash/`로 옮기고 자동으로 비우지 않는 것이다.
7. **무료 한도 세부**: 권장은 셋 다 "예"다.
   - "자료"는 PDF와 md만 센다.
   - 동기화로 받은 과목 안에 새로 만든 자료도 센다.
   - 여러 개 가져오기가 한도를 넘으면 전체를 거부한다.
8. **상품**: ID 확정(권장: 제안대로), 가격, 무료 체험, 가족 공유, EULA 종류(Apple 표준 또는 자체).
9. **AI**
   - BYOK 유지 여부(권장: 유지)
   - 호스팅 AI 서버 일정
   - `<무료 체험 횟수>`와 `<Pro 한도>`의 값
   - 1회의 정의(권장: 요청 1건)
10. **Google 로그인 방식**: 권장은 웹 흐름 유지다. 대안은 iOS 클라이언트로 하는 네이티브 로그인이다.
11. **Google iOS 클라이언트 값**: `<iOS Client ID>`와 `<iOS URL scheme>`이 자리표시자로 왔다. 실제 값이 필요하다.
12. **옛 동기화 서버 차단과 이미 올라간 자료 처리**: 데스크톱 철거 시점과 함께 정한다.
13. **fixture 관련**
    - 원본 위치(권장: 데스크톱 저장소)와 iPad 쪽 방식(권장: 사본과 커밋 고정)
    - 렌더 기대값의 기준 구현(권장: iPad)
14. **프로필**: 프로필 패널을 숨기고, "가져오기" 경로에서는 백업 요구를 생략한다. 권장은 둘 다 "예"다.
15. **출시 묶음**: 1.2 = 로그인과 구독, 1.3 = iCloud, 1.4 = Drive(권장).
16. **같은 이름의 "반달" 폴더 두 곳**: 파일 앱의 "나의 iPad › 반달"과 "iCloud Drive › 반달"이다.
    - 권장: 그대로 두고 설정 화면에 경로를 명시한다.
17. **동기화 상수**: 세션 파일 상한 1 MB(스펙)는 유지하고, Drive 같은 파일 업로드 최소 간격은 15초로 한다(권장).

---

## 부록 A. 실측 명령

```sh
# E4: 도메인과 issuer (공개 OIDC 문서, 읽기 전용)
dig +short auth.bandal.io CNAME
curl -s https://auth.bandal.io/auth/v1/.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])'
curl -s https://ukacrkcwiqafwpppshxb.supabase.co/auth/v1/.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])'

# E0: 백업 DB 사본에서 테이블 크기 (읽기 전용)
sqlite3 -readonly <사본>/bandal.db "SELECT name, SUM(pgsize)/1048576 FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 5;"
```

- E0의 크기 계산은 스크래치 공간의 일회용 스크립트로 했다. 저장소에는 넣지 않았다. 계산은 다음과 같다.
  1. `pdf_drawings` 중 살아 있는 행을 (과목, 경로, 쪽)으로 묶는다.
  2. 행마다 `{id, kind, page, t, data, style}`를 만든다. 이미지 relPath는 해시로 바꾼다.
  3. 묶음을 compact JSON으로 만든 뒤 gzip(레벨 6)한 크기를 잰다. 반올림 변형은 점의 x·y·p·t·tiltX·tiltY만 반올림한다.

---

## 부록 B. 승인과 결정 (2026-10-30)

설계안은 승인됐다. 아래 결정이 본문보다 우선한다.

| 항목 | 결정 |
|---|---|
| md_base, 노트 끝 페이지 추가 예외 | 수용. 공통 스펙 v2.1에 반영 |
| 필기 숫자 반올림 | 좌표(x, y) 소수 5자리, 압력(p) 3자리. t와 tilt는 결정 범위 밖이라 원래 정밀도 |
| 내보내기 판정 | 내용 해시. 추가로 파일 이름 변경이 `pdf_drawings.updated_at`을 바꾸지 않게 고친다(동기화 식별자 PR) |
| AI | BYOK 유지, 반달 AI 서버 없음. 로그인 불필요. Pro = 과목·자료 무제한 + AI 사용. 무료 = AI 월 20회, 기기에서 셈 |
| 로그인 | 선택 사항. 어떤 기능도 막지 않는다 |
| v1 제외 | 연결 폴더 과목. 텍스트 하이라이트는 `annotations` 구조가 `pdf_drawings`와 달라 제외 |
| 구독 | 가족 공유 끔, Apple 표준 EULA. 가격·체험은 아직 받지 못함. Google iOS 클라이언트 ID `565020221852-oc2noms2efphagpdldse4b8p7u9lls5e.apps.googleusercontent.com`, URL scheme `com.googleusercontent.apps.565020221852-oc2noms2efphagpdldse4b8p7u9lls5e`(10-31 받음. scheme은 ID를 뒤집은 값과 일치. Drive PR에서 쓴다) |

## 부록 C. 공통 스펙 v2.1과의 정합 (2026-10-30)

기준은 데스크톱 저장소 `feat/login-optional` 0e0a742의 `sync-fixtures/SPEC.md`(v2.1)와 fixture다. 스펙이 본문과 부록 B보다 우선한다. 처음 쓴 부록 C(옛 fixture 기준)는 이 절로 바꾼다.

**본문을 스펙에 맞춰 바꾸는 것**

| 본문 위치 | 본문 | 스펙 v2.1 |
|---|---|---|
| §2.2 | `rel_path` = 파일까지 포함한 경로, `name` = 확장자 없는 이름 | `rel_path` = 과목 안 폴더(루트 `""`), `name` = 확장자를 포함한 파일 이름, 둘 다 NFC |
| §2.2 경로 충돌 | 원격 문서를 옮긴다(기기마다 옮기는 문서가 달라질 수 있었다) | 살아 있는 문서끼리 겹치면 document_id가 가장 작은 문서만 그 이름을 쓰고, 나머지는 `"<확장자 뺀 이름> (<id 앞 4자>).<확장자>"`로 옮긴다 |
| §2.3 그리는 순서 | `created` | `(created, id)`. iPad 로드 쿼리(`NativePDFRepository.swift:253`)에 `id` 정렬을 더한다 |
| §2.3 반올림 | 점의 x·y 소수 5자리, p 3자리 | `data.box`의 x·y·width·height도 5자리. 동률은 0에서 먼 쪽(`.toNearestOrAwayFromZero`) |
| §1.4 Drive 루트 | 가장 오래된 폴더에 쓰고 읽기는 모두 합친다 | 만들 때 `appProperties.bandalRoot = "2"`. 여럿이면 `bandal.json`이 있고 `createdTime`이 가장 이른 폴더 하나만 쓴다 |
| §1.5 이름 규칙 | iCloud 플레이스홀더는 무시 | `.<name>.icloud`는 "아직 내려받지 않은 `<name>`"으로 다룬다 |
| §3.4 충돌 사본 | 감지한 기기가 `doc.upsert`를 낸다 | 누가 고치거나 지우기 전까지 파서가 계산하는 파생 문서다 |
| §10 expected.json | 객체는 정규 JSON 해시로 비교 | id를 키로 한 맵에 개체 전체를 담고 JSON 값으로 비교한다. 정규 JSON 규칙(§12.1-9)은 필요 없다 |
| devices | `name`만 정함 | `{name, platform, app_version, last_seen}`. iPad의 platform은 `"ipados"` |

**옛 fixture를 따르기로 했다가 v2.1에서 본문대로 정해진 것**: 묘비 최소형 허용, 이미지는 `relPath` 대신 `sha256`+`ext`, 노트 첨부 링크를 `../../assets/<sha256>.<ext>`로 바꾼 뒤 그 바이트로 md_hash(`md_assets` 없음), `bandal.json`은 `{"format":2}`뿐(루트 정체성은 제공자별 값), 범위 밖 좌표는 받을 때 클램프할 수 있고 클램프만으로 생긴 차이는 다시 내보내지 않음. 세션의 범위는 스펙이 정하지 않는다(포맷 결과와 무관).

**확인한 것**
- 필기 색 토큰 7종의 RGB가 iPad 렌더러(`NativePDFObjectRenderer.color`, `NativePDFInkSurface.color`)와 같다. `canvasLightInk`는 화이트보드 표시 전용이고 저장할 때 `ink`로 돌아간다.
- `render/v5-diameter.json` 4개 사례가 `NativePDFInkGeometryV5.widthFactors`와 1e-6 안에서 같다(최대 차이 5.0e-7). 렌더러를 바꿀 필요가 없다.
- fixture의 필기 숫자는 반올림돼 있고, 이미지는 `sha256`+`ext`, 새 md 문서의 `md_base`는 `null`이다.

**결정됨 (2026-10-31)**
- 과목 색 토큰은 스펙에 7종(`gold green blue pink violet orange red`)으로 적는다. iPad는 경계에서만 `purple`↔`violet`, `yellow`↔`gold`로 바꾸고 로컬 값은 그대로 둔다(`SyncAdapter.specCourseColor`/`localCourseColor`). 데스크톱은 `red`를 더한다.

**데스크톱 팀에 올릴 질문**
1. 노트가 이전 내용으로 돌아가면(같은 md_hash가 다시 나오면) 버전 그래프에 순환이 생겨 "승자는 항상 head"가 깨진다. iPad는 head를 "md_hash 집합 − md_base 집합"으로 계산하고 이 문장에 기대지 않는다.
2. 충돌 사본 이름에 쓸 `devices/<id>.json`이 아직 없을 때(쓰기 순서상 마지막)의 처리. 보류를 제안한다.
3. 대소문자만 다른 이름. iPad 파일 시스템은 구분하고 macOS·Windows는 구분하지 않는다. 경로 충돌을 어떤 비교로 판정할지 정해야 한다.
4. fixture에 없는 사례: 노트 첨부, 경로 충돌, 범위 밖 좌표, `.icloud`, format≠2, 잘못된 입력(모든 예제의 `errors`가 비어 있다), 노트 되돌리기.

질문 1–4는 2026-10-31에 데스크톱 팀에 전달됐다. 질문 2(보류)는 부록 D의 6번으로 철회한다.

## 부록 D. 데스크톱 PR #4의 스펙 제안 9건 (2026-10-31)

데스크톱 PR #4(`feat/sync-adapter`, `feat/login-optional`에 머지됨)의 "iPad 팀과 맞출 것" 9건에 대한 iPad 판정이다. 근거는 iPad PR2(`feature/sync-adapter`)에서 데스크톱 `format.ts`·`merge.ts`·`adapter.ts`를 Swift로 옮기며 확인했다.

| # | 제안 | 판정 | 근거와 덧붙일 것 |
|---|---|---|---|
| 1 | UUID는 소문자만. 대문자 경로는 패턴 밖 | 수용 | iPad 로컬 id는 이미 소문자다(`NativeLibraryRepository.swift:89`, `NativePDFRepository.swift:285`). 실기기 백업의 필기 12,292행 중 대문자 id는 0이다. 새로 만드는 device_id 등은 `uuidString.lowercased()`로 만든다 |
| 2 | 반올림 = binary64 × 10^n, 동률은 0에서 먼 쪽, ÷ 10^n | 수용 | Swift `(abs(x) * 1e5).rounded(.toNearestOrAwayFromZero) / 1e5`가 데스크톱 `roundAway`와 40만 개 값(동률 후보 10만 개 포함)에서 비트까지 같다. 덧붙일 문장: "결과가 −0이면 0으로 쓴다". `JSON.stringify`는 −0을 `0`으로 쓰지만 Foundation의 JSON 쓰기는 `-0`으로 쓴다 |
| 3 | 값이 틀린 이벤트·개체는 그것만 버리고, 파일 전체는 읽을 수 없을 때만 버린다 | 수용 + 경계 명시 | "읽을 수 없음"의 경계가 두 파서에서 다르다(아래 표). iPad는 `JSON.parse`와 같게 읽는 엄격한 리더(`SyncJSON`)를 새로 썼다. 덧붙일 문장: "JSON 파일은 BOM 없는 올바른 UTF-8이다. 잘못된 UTF-8, 짝 없는 서로게이트, 깊이 64 초과는 파일 오류다". 데스크톱 쪽 변경은 `TextDecoder('utf-8', {fatal: true, ignoreBOM: true})`, 문자열 `isWellFormed()` 검사, `allFinite`에서 깊이 세기다 |
| 4 | `t`·`created` < 2100-01-01 | 수용 | 읽는 기기의 시계에 기댄 상한은 기기마다 결과가 달라진다. 고정 상한만 결정적이다. iPad도 0 이상 정수, 4102444800000 미만으로 검사한다 |
| 5 | md 이벤트는 `md_hash`와 `md_base`를 함께 보낸다. 없으면 null | 수용 | 본문 §2.5와 같다. 빠진 base는 head를 하나 늘릴 뿐이라(사본이 하나 더 생길 수 있음) 손실이 없다 |
| 6 | 충돌 사본 기기명: NFC, `/`·제어 문자 → `_`, 기기 파일이 없으면 device_id 앞 8자, 진 버전을 여러 기기가 썼으면 `(t, device_id)`가 가장 큰 기기 | 수용, iPad 질문 2(보류) 철회 | 보류하면 기기 파일이 끝내 오지 않을 때 사본이 영영 보이지 않는다. 덧붙일 것 두 가지. (a) 사본이 파생 상태인 동안에는 머지할 때마다 이름을 다시 계산한다. 기기 파일이 늦게 와도 모든 기기가 같은 이름으로 모인다. (b) 사본도 경로 충돌 규칙에 넣는다. 지금은 `renames`가 `state.docs`만 본다. 사용자가 고쳐 둔 "강의 (충돌 사본 iPad).md"가 있는데 같은 iPad에서 또 충돌이 나면 새 사본이 같은 이름을 받는다. 제안: 파생 사본은 살아 있는 문서와 이름이 겹치면 `(<id 앞 4자>)`를 붙이고, 사본끼리는 id가 작은 쪽이 이름을 쓴다 |
| 7 | 노트 내용은 작성 기기 파일에서 먼저, 없으면 해시가 같은 다른 기기 파일 | 수용 + 순서 명시 | 내용은 해시로 같지만 `file` 경로가 `expected.json`에서 비교된다. 데스크톱 구현의 순서(작성 기기 파일 → seq 큰 것 → 경로 큰 것)를 스펙에 적는다. iPad도 같은 순서다 |
| 8 | 같은 `(t, device_id)`에 다른 값이 오면 쓰기 규칙 위반. 데스크톱은 JSON 문자열 비교 | 수정 제안 | 쓰기 규칙 위반이라는 점은 같다. 다만 JSON 문자열은 키 순서와 숫자 표기에 따라 달라지고, Swift 파서는 키 순서를 남기지 않는다. 그래서 두 앱이 다른 값을 고를 수 있다. 제안: 같은 `(t, device_id)`면 seq가 큰 파일, 같은 파일이면 배열에서 뒤의 것이 이긴다(나중에 쓴 것). 두 앱 모두 경로와 배열 위치만 보면 된다. 같은 객체를 같은 t로 다시 쓰는 실제 경우(앱 업데이트 뒤 다시 내보내기, 자기 파일 감사 §1.9)에도 최신 파일이 이긴다. iPad PR2는 이 규칙으로 구현했다 |
| 9 | 크기 상한은 MiB, ext는 `[a-z0-9]{1,16}`, 경로의 page는 앞 0 없는 양의 정수이고 100000을 넘으면 오류 | 수용 | iPad 로컬 첨부는 확장자가 대문자이거나 없을 수 있다(`첨부-<uuid>`). 내보낼 때 소문자로 바꾸고, 없거나 규칙에 맞지 않으면 `bin`을 쓴다 |

**파서 경계 실측** (Node 24 `JSON.parse`/`gunzipSync` 대 Foundation `JSONSerialization`)

| 입력 | Node | Foundation | iPad `SyncJSON` |
|---|---|---|---|
| UTF-8 BOM | 오류 | 받음 | 오류 |
| UTF-16 파일 | 오류 | 받음 | 오류 |
| 끝 쉼표 `[1,]` | 오류 | 받음 | 오류 |
| 중복 키 | 마지막 값 | 첫 값 | 마지막 값 |
| 잘못된 UTF-8 | U+FFFD로 바꿔 받음 | 오류 | 오류(제안) |
| 짝 없는 서로게이트 `"\ud800"` | 받음 | 오류 | 오류(제안) |
| `1e999` | Infinity → 데스크톱이 오류 처리 | 오류 | 오류 |
| gzip 멤버 여러 개 | 이어서 읽음 | — | 이어서 읽음 |
| gzip 뒤 0으로 시작하는 바이트 | 무시 | — | 무시 |
| gzip 뒤 그 밖의 바이트 | 오류 | — | 오류 |

**데스크톱 첫 커밋과 같은 iPad 수정**: iPad 편집기도 과목 이미지에 `widthPx`/`heightPx`를 보내지만(`App/PDF/PDFWorkspaceView.swift:508`) 검증이 공유 보드 이미지에만 남겼다. 데스크톱 `5561f60`과 같게 양의 정수 쌍이면 남긴다(`NativePDFRepositoryValidation.data`). 그래야 fixture의 이미지 객체가 왕복한다.

## 부록 E. 스펙 v2.2 초안(데스크톱 PR #6)과 제안 10번 (2026-10-31)

PR #6(`feat/sync-spec-v2.2`, 19dba25)은 아직 열려 있다. 머지되면 fixture 05–09를 받아 iPad PR2를 갱신한다.

**제안 10번: 되돌리기와 동시 편집이 겹치면 손실. 판정: 수용**

- 제안: "버전 v는 base가 v의 해시이고 t가 v보다 큰 다른 버전이 있을 때만 head가 아니다."
- 지금 규칙은 해시 단위로 "어디서든 base로 쓰였으면 head가 아니다"라서, 되돌린 버전(H0)이 옛 H0의 자식(H1) 때문에 head에서 빠진다. 제안은 나중에 생긴 버전만 대체할 수 있게 해서 이 경우를 고친다.
- 안전성
  - 제안의 head 집합은 지금 규칙의 head 집합을 늘 포함한다. 그래서 사본이 줄어드는 경우는 없고 늘기만 한다.
  - v를 보고 만든 버전은 clock 규칙 때문에 t가 늘 v보다 크다. 그래서 진짜 후손은 빠짐없이 v를 대체한다.
  - v를 보지 않고 같은 내용(같은 해시)에서 출발한 버전이 t가 더 커서 v를 대체하는 경우가 있다. 예: 오프라인이던 C가 원래 H0에서 H3를 만들고, 그 사이 A가 H1을 H0으로 되돌렸다. 이때 A가 공통 조상(H0)에서 바꾼 것은 없으므로 H3만 남는 것이 3-way 병합과 같은 결과다. 손실이 아니다.
  - 같은 t는 대체하지 않는다. 사본이 하나 더 생길 수는 있어도 사라지지는 않는다.
  - 승자(md_hash의 LWW)는 t가 가장 크므로 늘 head다. 순환도 생기지 않는다. 그래서 v2.2의 "승자가 head가 아닐 수 있다" 문장은 "승자는 늘 head다"로 돌아간다.
- 구현: 문서마다 "base로 쓰인 해시 → 그 버전들의 최대 t"를 한 번 모은 뒤, v는 `maxT[v.hash] > v.t`일 때만 head가 아니다. O(n)이라 노트 저장이 수천 번 쌓여도 느려지지 않는다.
- 요청: 제안 10의 경우와 위 C의 경우를 담은 예제(10번)를 더한다. 01–09의 결과는 바뀌지 않으므로 지금은 두 앱이 이 규칙을 같게 구현했는지 확인할 예제가 없다.

**v2.2 초안에서 맞출 것**

1. 변경 3번(충돌 사본은 기기 파일이 와야 만든다)은 iPad 질문 2(보류)를 따른 것이다. 그런데 부록 D 6번에서 그 질문을 철회하고 "device_id 앞 8자 + 파생 상태 동안 이름 재계산"을 수용했다. PR #6에 부록 D를 반영할 때 이 줄과 05 예제의 보류된 사본도 함께 정해야 한다. iPad 권장은 6번 답이다. 보류는 기기 파일이 끝내 오지 않으면(첫 flush 도중 기기가 사라진 경우 등) 진 버전이 영영 보이지 않아 "손실 0" 원칙을 어긴다. 이름이 잠시 device_id로 보이는 것은 겉모습 문제다.
2. 변경 4번(경로 충돌 대소문자 무시)의 "로캘과 무관한 기본 소문자 변환"은 두 앱에서 결과가 다르다. JS `toLowerCase()`는 단어 끝 Σ를 ς로 바꾸고(Final_Sigma), Swift `lowercased()`는 σ로 바꾼다. 예: `"ΌΣΟΣ"` → JS `όσος`, Swift `όσοσ`. 제안: "코드 포인트마다 따로 기본 소문자 매핑을 적용한다(문맥 규칙 없음)". JS는 `[...s].map(c => c.toLowerCase()).join('')`, Swift는 `s.unicodeScalars.map { $0.properties.lowercaseMapping }.joined()`로 같은 결과를 낸다(위 예 모두 `όσοσ`).

**결과 (2026-10-31)**

- 데스크톱 PR #6이 `30ec020`으로 머지됐다. 위 두 항목과 제안 10이 모두 반영됐다.
  - 충돌 사본은 노트 파일이 없을 때만 보류한다. 기기 파일이 없으면 device_id 앞 8자를 쓴다.
  - 경로 충돌은 코드 포인트 단위로 소문자로 바꿔 비교한다.
  - 제안 10의 예제는 11번이다. 10번은 동률 규칙 예제다.
- iPad PR #2는 v2.2 머지 직전에 main에 머지됐다(`9b5b967`). v2.2 갱신분은 PR #3(`feature/sync-spec-v2.2`)으로 올렸다. fixture 11개가 모두 맞는다.

## 부록 F. 로컬 DB 연결(PR3)에서 찾은 스펙 문제 (2026-10-31)

**경로 충돌 비교가 실제 파일 시스템보다 느슨하다 (제안)**

- v2.2는 경로 충돌을 "NFC + 코드 포인트마다 소문자"로 비교한다.
- 그런데 macOS의 대소문자 무시 APFS와 Windows NTFS는 대소문자를 접어(case folding) 비교한다.
  - 예: `ΟΔΥΣΣΕΥΣ 1.pdf`와 `οδυσσευς 1.pdf`(끝 시그마 ς)는 스펙상 다른 이름이라 이름을 바꾸지 않는다.
  - 하지만 Mac 볼륨에서는 같은 파일이다. 실측 결과 `ΟΔΥΣΣΕΥΣ 1.pdf`가 있으면 `οδυσσευς 1.pdf`와 `οδυσσευσ 1.pdf`가 모두 이미 있는 것으로 나온다.
  - 그래서 fixture 06의 d2c0는 데스크톱에서 놓을 자리가 없다.
- iPad 시뮬레이터는 경로를 대소문자 구분으로 찾지만 Mac 볼륨에 저장한다. 그래서 06의 QnA/qna, Lecture/lecture, Σ/ς 문서 4개를 만들지 못한다. 시뮬레이터에서만 생기는 일이다.
  - 실제 기기에서는 대소문자를 구분할 것으로 본다. 확인이 필요하다.
  - 스펙의 "iPadOS도 대소문자만 다른 이름을 같은 이름으로 본다"는 문장도 기기에서 확인이 필요하다.
- 제안: 코드 포인트마다 "대문자로 바꾼 결과가 한 코드 포인트이면 그것을 소문자로 바꾼 값, 아니면 소문자"로 비교한다.
  - Σ, σ, ς가 모두 σ가 된다. ß는 대문자가 두 글자(SS)라 ß로 남는다.
  - JS: `[...s].map(c => { const u = c.toUpperCase(); return [...u].length === 1 ? u.toLowerCase() : c.toLowerCase() }).join('')`
  - Swift: 스칼라마다 `uppercaseMapping`이 한 스칼라이면 그 스칼라의 `lowercaseMapping`, 아니면 자기 `lowercaseMapping`
  - 06의 기대값이 바뀐다. d2c0도 `οδυσσευς 1 (d2c0).pdf`로 옮겨진다.
  - 검증: Node 24(Unicode 16.0)와 Swift에서 모든 코드 포인트를 비교했다. 값이 바뀌는 1,483개가 모두 같다.
    - 예: Σ·ς → σ, ẞ → ß, ı → i, İ → i̇(2 코드 포인트)
    - 파일 시스템보다 넓게 같다고 보는 쪽(ı와 i)은 이름에 접미사가 붙을 뿐이다. 좁게 보면 디스크에서 파일이 부딪친다.

**결과 (2026-11-01)**: 제안이 스펙 v2.3에 들어간다(데스크톱 반영 중). iPad는 v2.3 fixture를 받은 뒤 `pathKey`를 바꾼다. 실기기 iPadOS도 대소문자를 구분한다(사용자 확인). 스펙의 iPadOS 문장은 데스크톱이 고친다.

## 부록 G. 스펙 v2.3 PDF 재바인딩 규칙의 iPad 구현 (2026-11-01)

사용자가 전달한 규칙: `doc.upsert`에 `pdf_prev_sha256`을 싣는다. 받는 쪽은 로컬 바인딩 sha가 그 값과 같으면 재바인딩하고 필기를 유지한다. 다르면 보호한다. 데스크톱 문안이 아직 없어 아래처럼 읽었고(iPad PR #4), 문안이 나오면 대조한다.

**보내는 쪽**

- `pdf_sha256`을 보낼 때는 언제나 `pdf_prev_sha256`을 함께 보낸다. 바뀌지 않았어도 함께 보낸다. 레지스터는 필드마다 LWW이므로, 나중 쓰기가 `pdf_sha256`만 보내면 앞 쓰기의 `pdf_prev_sha256`과 짝이 어긋난다.
- 값은 마지막으로 주고받은 `pdf_sha256`이다. 단, 이 기기의 바인딩이 새 PDF를 따라왔을 때만 그렇다. 바인딩 sha가 새 sha와 같고, 근거가 `page-history`(앱 안 페이지 변경)나 `sync`(동기화 재바인딩)인 경우다.
- 그 밖에는 null이다. 앱 밖에서 바뀐 바이트, 열어 본 적 없이 교체된 뒤 처음 연 PDF(`first-observed`), 처음 보내는 문서가 여기에 해당한다.

**받는 쪽**

- `pdf_prev_sha256`은 `pdf_sha256`과 stamp가 같을 때만 센다. 같은 쓰기에서 온 값만 인정한다. 그래서 v2.2 기기가 나중에 PDF만 바꿔도 앞 기기의 주장을 물려받지 않는다.
- 로컬 바인딩 sha가 그 값과 같으면 재바인딩한다(근거 `sync`). 다르면 바인딩을 그대로 둔다. 그러면 "PDF 원본이 기존 필기와 다릅니다" 보호가 동작하고, 이전 바이트는 PDFOriginals에 남는다.
- 이 iPad에서 열어 본 적 없는 PDF에 다른 기기의 필기가 이미 있으면, 바이트를 바꾸기 전에 지금 바이트로 바인딩한다(`checkBinding`). 그렇게 해야 보호가 열어 본 PDF와 똑같이 동작한다.
- 그 경로에 필기와 주석이 하나도 없으면 지킬 것이 없으므로 바인딩이 따라간다. 이 iPad의 바인딩 확인은 필기가 없어도 sha가 다르면 경고하기 때문이다. **데스크톱 문안과 대조 필요.**
- 지웠다가 다시 나타난 문서를 놓을 때도 같은 규칙을 쓴다.

**검증**

- 송신 규칙 2개와 수신 규칙 5개를 하나씩 따로 되돌리면, 매번 해당 테스트가 실패한다(`SyncStoreTests`).
- 데스크톱 문안이 나오면 같은 장면(끝 덧붙이기, 앱 밖 교체, 처음 연 PDF, v2.2 기기의 뒤따르는 쓰기)을 fixture로 맞추자고 제안한다.

## 부록 H. 스펙 v2.4의 iPad 구현 (2026-11-01, PR6)

데스크톱 #12(`63f8c084`)의 v2.4와 예제 13·14를 고정했다. 사용자는 데스크톱 제안(삭제된 과목에 문서를 쓰는 기기는 그 과목도 되살린다)을 수용했다. 부록 G의 받는 쪽 규칙("같은 쓰기의 `pdf_prev_sha256`과 같을 때만")은 아래 덧붙이기 연결로 바뀌었다.

**머지** (데스크톱 `merge.ts`와 같다. 적합성 예제 01–14 통과)

- 문서의 삭제 레지스터는 자기 것과 과목 것 중 늦은 시점을 쓴다. 값은 둘 중 하나라도 삭제면 삭제다. 그래서 과목이 되살아나면 tombstone이 없는 문서도 살아난다.
- 삭제된 과목에는 충돌 사본을 만들지 않는다. 경로 충돌과 보류는 살아 있는 문서만 보므로 저절로 빠진다.
- `rebindFrom`: 모든 `doc.upsert`의 `pdf_prev_sha256 → pdf_sha256`을 문서마다 모으고, 이긴 sha256에서 거꾸로 따라간 sha256 목록을 낸다. 이긴 것은 빼고 정렬한다. 한 번 지난 sha256은 다시 보지 않는다.

**적용**

- **재바인딩**: 바인딩 sha256이 `rebindFrom` 안에 있으면 따라간다. 그 경로에 지워지지 않은 필기와 하이라이트가 하나도 없을 때도 따라간다. 지운 획은 필기로 치지 않는다(데스크톱과 같다).
- **원격 과목 삭제**: 이 iPad에 아직 나가지 않은 파일이 있으면 과목을 남긴다. 새 파일이나 마지막 교환 뒤 바뀐 파일이 그렇다.
  - 이때 과목 레지스터만 삭제로 적는다. 그러면 outbox가 과목을 모든 필드로 다시 보내고(되살리기), 바뀐 문서는 그 안으로 나간다.
  - 같은 과목의 다른 문서는 각자의 tombstone 때문에 이 iPad에서도 지워진다.
- **남길 것이 없으면**: 과목만 소프트 삭제하고 폴더와 문서 경로는 남긴다(앱 안에서 지울 때와 같다). 문서 레지스터에는 삭제를 적는다. 그래서 이 iPad에서 과목을 되살리면 문서마다 `doc.upsert`가 나간다.
- **과목이 돌아오면**: 과목과 함께 지워져 경로를 지키던 문서 가운데 아무도 다시 쓰지 않은 것을 지운다.
- **다른 이름으로 돌아온 PDF**: 여기서 지운 PDF가 원격 이름 변경으로 다른 경로에 돌아오면, 그 문서의 획(교환한 id)을 새 경로로 옮긴다. 데스크톱 퍼즈가 찾은 문제와 같다.

**보내기**

- 과목을 지우면 `course.delete`와 함께, 살아 있는 문서마다 `doc.delete`를 쓴다. 그 문서들은 경로를 지키다가, 과목이 돌아오면 다시 보내거나 지운다.
- iPad UI에는 과목 삭제와 복원이 없고 보관만 있다. 그래서 이 송신 경로는 앞으로의 UI를 위한 것이다. 덮어쓰기의 대기 삭제는 원래 클라우드에만 있는 문서를 모두 지우므로 이미 v2.4에 맞다.
- **`pdf_prev_sha256`(확인)**: 마지막으로 주고받은 sha256에서 지금 sha256까지 페이지 이력이 끝 덧붙이기로만 이어질 때 그 값을 쓴다.
  - 덧붙이기 경로는 쪽 패널의 "+", 마지막 쪽의 "아래에 페이지 추가", 당겨서 추가 세 가지이고, 모두 `pdf:restructure`로 이력에 남는다.
  - 동기화 사이에 여러 번 덧붙이면 한 단계로 나간다. 그사이 쪽 순서를 바꿨거나 앱 밖에서 바뀌었으면 null이다.

**열린 PDF의 원격 필기** (PR6)

- 장벽 안에서, 필기만 바뀐 PDF의 편집기는 다시 열지 않는다. 대신 저장된 획을 다른 창의 쓰기처럼 받는다(`receivePeerSnapshot`).
  - 바뀐 획만 다시 그린다. 그 획을 건드린 실행 취소만 사라진다. 화면 위치, 쪽, 도구는 그대로다.
- 필기 엔진과 렌더러는 바꾸지 않았다. 같은 PDF를 두 창에서 열 때 이미 쓰는 경로다.
- PDF 바이트가 바뀌었거나 다시 그리지 못하면(아직 여는 중 등) 지금처럼 다시 연다.

**독립 리뷰로 고친 것** (HIGH 1, MEDIUM 2, LOW 3)

- 과목을 지울 때 `doc.delete`는 이 기기가 그 과목 것으로 아는 문서에만 쓴다. 다른 과목으로 옮겨졌지만(v1은 그 이동을 적용하지 않는다) 파일은 아직 이 과목 폴더에 있는 문서는 빼야, 옮겨 간 과목에서 살아남는다.
- 되살리기를 apply에 기대지 않는다. outbox가 루트에서 삭제된 과목 목록을 받아, 그 과목에 문서를 쓰는 flush에서 과목을 모든 필드로 먼저 쓴다(데스크톱 `reviveCourse`와 같다). 그래서 장벽이 이번 차례에 돌지 못해도 되살아난다.
- 보내지 않은 필기(아직 나가지 않은 획)도 "바뀐 것"으로 친다. 그런 PDF는 다른 기기가 지웠어도 남고 다시 나가며, 과목도 함께 돌아온다.
- 과목을 남길 때는 다른 기기가 지우기 전에 바꾼 이름·색을 먼저 받는다. 그래야 되살리기가 그 변경을 덮지 않는다.
- 과목 폴더를 읽지 못하면 그 과목의 삭제를 다음 차례로 미룬다. 다시 그리기는 그 PDF의 쓰기 차례(`serial`) 안에서 한다.

**남는 경쟁**

- 과목이 지워진 줄 모르는 기기가 그 과목에 쓴 문서는 삭제로 보인다(예제 13의 문서 3). 스펙이 받아들인 결과다.
- iPad에서는 그 파일이 숨은 과목 폴더에 남는다. 루트 이력에도 남는다.

## 부록 I. Google Drive provider의 iPad 구현 (2026-11-01, PR7)

§1.4와 부록 C의 루트 규칙을 따랐다. 클라이언트 ID와 URL scheme은 부록 B의 값이다.

- **인증**: SDK 없이 `ASWebAuthenticationSession`과 PKCE(S256)를 쓴다. 스코프는 `openid email drive.file`이다.
  - 동의 화면에서 Drive를 빼고 허용하면 "Google Drive 파일 접근을 허용해야 동기화할 수 있어요"로 멈춘다.
  - 새로 로그인한 계정은 연결을 마칠 때까지 메모리에만 둔다. 시트를 닫으면 남지 않는다.
  - 저장된 토큰이 죽었으면(만료, 사용자가 권한 회수) Drive를 고를 때 다시 로그인한다.
  - URL scheme은 Info.plist에 등록하지 않았다. `ASWebAuthenticationSession`은 등록 없이 콜백을 받는다. 등록하면 앱의 `onOpenURL`이 그 URL을 파일로 가져오려 한다(§5 문장과 다르다. 11-01 승인).
  - 토큰 교환 응답의 id_token에서 계정 식별자(`sub`)와 이메일을 읽는다. Google 토큰 엔드포인트에서 TLS로 직접 받은 값이라 서명은 검증하지 않는다.
  - refresh token은 이 프로필의 키체인 항목 `drive.account[.<프로필 폴더>]`에 둔다(`AfterFirstUnlockThisDeviceOnly`). access token은 메모리에만 둔다.
  - `invalid_grant`면 "Google에 다시 연결해 주세요"를 띄우고, 설정에 "Google에 다시 연결" 버튼이 나온다.
- **계정과 루트**: 마지막으로 연결한 루트의 계정을 `sync_account`에 `icloud:<토큰>` 또는 `drive:<sub>`로 둔다.
  - 다른 계정이나 다른 provider는 다른 루트다. 그래서 연결할 때 이전 루트와의 짝을 잊는다(`forgetRoot`).
  - PR5의 `icloud_account`는 읽을 때만 대신 쓴다.
- **목록**: 처음에는 `files.list` 전체를 받고, 그 뒤에는 `changes.list`로 바뀐 것만 받는다. page token은 메모리에만 둔다(앱을 다시 켜면 전체 목록부터).
  - 텍스트 파일은 목록을 돌려주기 전에 6개씩 내려받는다. PDF와 첨부는 그 뒤에 내려받고, 다 받으면 변경 신호를 보낸다. iCloud와 같은 계약이다.
  - 내려받은 파일은 `Caches/BandalDrive/<sub>/<파일 id>-<md5>`에 둔다. 시스템이 지우면 다시 받는다.
- **루트 고르기(스펙 v2.5, 데스크톱 #17)**: 후보 가운데 `bandal.json`이 있는 것, 오래된 것, id가 작은 것 순으로 하나를 쓴다. 그 아래에서는 같은 이름 폴더를 합쳐 읽고, 쓰기는 가장 오래된 폴더에 한다.
  - 루트를 만들 때 `properties`와 `appProperties` 둘 다에 `bandalRoot = "2"`를 붙인다. `appProperties`는 쓴 클라이언트에만 보이고, `properties`는 같은 프로젝트의 모든 클라이언트에 보인다.
  - 후보는 두 표시 중 하나가 보이는 폴더다. 위치와 이름은 보지 않는다.
  - 표시가 보이는 폴더가 하나도 없을 때만 이름이 "Bandal"이고 `bandal.json`이 있는 폴더가 후보다. v2.5 전에 다른 클라이언트가 `appProperties`에만 표시한 루트다.
  - #8까지는 표시 없는 맨 위 "Bandal" 폴더도 늘 후보로 받았다. 11-02 후속 PR에서 위처럼 바꿨다.
- **쓰기**
  - 새 파일은 `generateIds`로 미리 받은 id로 만든다. 409가 오면 그 id의 md5를 비교해, 같으면 성공으로 본다.
  - 자기 파일은 같은 id에 media로 덮어쓴다. 5 MB 이상은 resumable 업로드 한 번으로 보낸다. 세션 URI는 저장하지 않는다.
  - 같은 파일은 15초에 한 번만 올린다. "지금 동기화"는 그 창을 건너뛴다.
- **오류**: 401이면 토큰을 한 번 갱신한다. 429, 5xx, 할당량 403이면 1·2·4·8초로 기다리며 다시 시도한다. 그 밖의 403은 바로 오류다.
- **변경 감지**: 30초마다 `changes.list`를 확인한다. 유휴 5분 규칙과 백그라운드로 갈 때 바로 올리기는 하지 않았다.
- **연결 해제**: 이 기기의 키체인과 내려받은 캐시에서 계정을 지운다. revoke는 하지 않는다(§1.4와 다르다. 11-01 승인, 스펙 v2.5).
  - revoke는 사용자 계정에서 이 앱의 권한 전체를 끊는 것으로 보인다. 그러면 한 iPad에서 끄는 순간 다른 기기의 Drive 동기화도 끊긴다. 권한 회수는 사용자가 Google 계정 설정에서 한다.
  - iCloud로 옮기면 Google 계정을 잊는다. 가져오기(새 프로필)에서는 계정을 새 프로필의 키체인으로 옮긴다.
  - 같은 프로젝트의 Gmail 연결 해제(`DesktopMailService`)도 revoke하지 않는다(스펙 v2.5). 전에는 revoke해서 그 계정의 데스크톱 Drive 동기화까지 끊었다.
- **끄기와 프로필 전환**: 진행 중인 주기를 취소한다. 15초 창이나 재시도 대기에 막히지 않는다. 커밋은 모든 쓰기가 끝난 뒤라 중간 취소는 안전하다.
- **남은 확인**: 실계정에서 E3(데스크톱 OAuth 클라이언트와 iOS 클라이언트가 같은 프로젝트에서 서로의 `drive.file` 파일을 보는지)를 봐야 한다. Google Cloud 콘솔의 게시 상태는 "프로덕션"이다(11-01 확인). 그래서 refresh token의 7일 만료는 해당하지 않는다(§11).

## 부록 J. 스펙 v2.6 첫 업로드 표시의 iPad 구현 (2026-11-02)

결정(11-02): 먼저 쓰기(iPad 제안)와 완료 표시(데스크톱 제안)를 합친다. 11-02 Drive 확인에서 iPad가 `bandal.json`을 첫 업로드 맨 끝(첫 파일보다 3분 18초 뒤)에 써서 Mac이 그동안 missing-root를 본 것이 계기다.

- **쓰는 순서(첫 업로드)**: `bandal.json` = `{"format":2,"initial_upload":"<device_id>","started":<ms>}` → `devices/<me>.json` → pdf/assets → ink/notes → log → `bandal.json` = `{"format":2}`.
  - `started`는 사용자 결정(11-02)이다. 스펙 v2.6(데스크톱 #20, 8edb36db)에는 아직 없다. devices 파일이 없을 때의 판정에 쓴다.
  - devices 파일을 앞에 쓰는 이유: 다른 기기가 그 기기의 `last_seen`을 읽어야 한다(스펙 v2.6 1).
  - devices 파일은 `name`과 `last_seen`(ms)을 쓴다. `platform`, `app_version`은 아직 쓰지 않는다.
  - 첫 업로드 중에는 쓰기 사이가 10분을 넘으면 devices 파일을 다시 쓴다(스펙 v2.6 4).
- **끊긴 첫 업로드**: 다음 실행에서 `initial_upload`가 자기 id면 devices 파일부터 쓰고 이어서 올린 뒤 표시를 지운다. 이로써 `CloudSyncEngine` 110–112줄의 "자기 루트를 missing-root로 보고 영영 멈춤"이 없어진다.
- **표시 지우기**: 지우기 직전에 루트를 다시 나열해 `bandal.json`을 읽고, 아직 자기 표시일 때만 지운다. 같은 빈 루트를 두 기기가 함께 시작해 표시를 덮어쓴 경우다.
- **다른 기기의 표시(연결하려는 기기만)**
  - 판정: `last_seen`이 있으면 |지금 − last_seen| ≤ 1시간일 때 진행 중이다. 없으면(devices 파일이 없거나 값이 없음) |지금 − started| ≤ 5분일 때 진행 중이다. 둘 다 없으면 중단이다.
    - 스펙 v2.6 본문은 "기기 파일이나 `last_seen`이 없으면 중단"이다. `started` 규칙이 그 자리를 대신한다(사용자 결정). `started`도 양쪽으로 보는 것(5분 넘게 앞선 시각도 중단)은 iPad의 해석이다. `last_seen` 규칙과 같게, 시계가 크게 틀린 기기가 남을 붙잡지 않게 한다.
  - 진행 중: 미리보기가 "‘이름’에서 처음 올리는 중이에요. 30초마다 다시 확인해요."를 보이고 30초마다 다시 미리 본다. 끝나거나 중단되면 연결 시트가 뜬다. 연결 요청은 거부한다(`SYNC_INITIAL_UPLOAD`).
  - 중단: 연결 시트에서 합치기와 가져오기만 된다. 덮어쓰기는 숨기고 서비스에서도 거부한다.
  - 표시와 그 기기 파일은 나머지보다 먼저 읽는다. 루트의 다른 파일이 아직 내려오는 중이어도 판정한다. 그 기기 파일이 내려오는 중이면 판정하지 않는다("내려받는 중"으로 보인다).
- **이미 연결된 기기**: 표시와 상관없이 동기화한다(스펙 v2.6 "표시 읽기"). 처음 구현은 진행 중일 때 기다렸는데, 스펙에 맞춰 뺐다.
- **연결 로그(스펙 v2.6 5)**: 프로필 폴더의 `Logs/bandal.log`(기존 기기 기록)에 남긴다. 지금 화면에서 여는 곳은 없어 `devicectl`로 앱 컨테이너를 받아 본다.
  - 남기는 때: 미리보기가 기다리거나(`uploading`, `downloading`) 막혔거나(`update-required` 등) 실패했을 때, 연결이 실패했을 때, 연결이 Drive 폴더를 새로 만들게 될 때(`new-root-folder`).
  - 줄: `sync.<preview|connect> channel=<icloud|drive> code=<결과>`, `sync.<…>.root … code=entries:<n>:bandal_json:<1|0>:initial_upload:<id|->`. Drive는 본 폴더마다 `sync.<…>.folder … code=<id>:<createdTime>:<mark|name>:<bandal.json 1|0>:<고름 1|0>:<이름>`.
  - 반달 iPad 로그 규칙대로 오류 메시지는 넣지 않고 코드만 넣는다. 이름은 영숫자와 `_.:-` 밖의 글자가 `_`로 바뀐다.
  - iPad는 Drive 루트 폴더를 연결 때가 아니라 첫 쓰기 때 만든다. 그래서 "새로 만듦"은 연결 시점에 고른 폴더가 없다는 것으로 남긴다.
- **Drive**: 같은 파일 다시 쓰기의 15초 창에서 `bandal.json`은 뺀다. 표시를 지우는 쓰기가 기다리지 않게 하기 위해서다.
- **적합성**: fixture를 데스크톱 8edb36db(#20 머지)로 고정했다. 예제 15–17과 `expected.json`의 `initial_upload`(`{device, last_seen}`)를 맞췄다. `started`는 아직 예제에 없다.
- **남은 것**: 데스크톱이 `started`를 스펙과 fixture에 넣으면 다시 고정한다. 30초 재확인은 화면 동작이라 단위 테스트가 없다.

## 부록 K. 반달 멤버십의 iPad 구현 (2026-11-02, PR8)

실기기 Drive 테스트 A-3~A-8 통과(11-02) 뒤 시작했다. 결정은 부록 B와 11-02 결정을 따른다.
- 무료 = 이 iPad에서 만든 과목 1개·자료 10개, AI 월 20회(본인 키).
- 구독 그룹은 "Bandal Membership"이다. 지금 등급은 Plus 하나다: `app.bandal.ipad.plus.monthly`(₩3,900)와 `app.bandal.ipad.plus.yearly`(₩29,000), 7일 무료 체험. Plus = 무제한.
- Pro는 나중에 같은 그룹의 위 등급으로 들어온다. 지금은 등급 구조만 열어 둔다.
- 로그인·동기화와 서로 조건을 걸지 않는다. ASC 입력값은 `docs/release/app-store-membership.md`에 있다.

- **판정(§8.1)**: `Membership`(`App/Services/Membership.swift`)이 `Transaction.currentEntitlements` 중 환불되지 않은 것의 제품 ID를 `Membership.products`(제품 ID → 등급)로 바꾸고, 가장 높은 등급을 이 기기의 등급으로 본다(`Tier`: `free` < `plus`). 만료는 StoreKit이 목록에서 뺀다. 서버로 보내는 것은 없다.
  - Pro를 더할 때는 `Tier`에 `pro`를 `plus` 다음에 넣고 `products`에 두 ID를 넣는다. 무료 한도는 `plus` 이상이면 풀린다.
  - 앱 시작 때 `Transaction.updates`를 듣고 `Transaction.unfinished`를 마무리한다.
  - 저장소 큐에서 읽도록 잠금으로 된 등급 사본을 두고, `Membership.unlimited`(Plus 이상)로 읽는다.
  - StoreKit이 한 번 답하기 전에는 아무것도 막지 않는다. 구독자가 앱을 켜자마자 페이월을 만나지 않게 하고, App Store가 답하지 않는 기기(Apple ID 없음 등)에 살 수 없는 페이월을 띄우지 않기 위해서다.
  - `appAccountToken`: 로그인 중이면 Supabase user id, 아니면 넣지 않는다. 어느 쪽이든 구매와 복원은 된다.
- **무료 한도 검사(§8.2)**: `DesktopRuntime.handle`이 채널 실행 전에 런타임의 라이브러리와 함께 `limits`를 부르고, 앱 조립(`NativePlatformServices`)이 Plus 미만일 때 `FreeTier.check`를 건다. 단위 테스트의 런타임에는 걸지 않는다.
  - 새 `NativeLibraryRepository`를 만들지 않는다. 새 인스턴스는 첫 호출에서 남은 경로 변경 의도를 되돌리는 복구를 돌리기 때문이다.
  - 과목: `courses:create`, `courses:addFromFolder`, `learning:create`(placement가 standalone이거나 없을 때. 학습 공간 과목을 만든다).
  - 자료(PDF·md): `notes:create`, `pdfNotes:create`, `pdf:recoverPagesCopy`(각 1), `materials:import`(경로 중 PDF·md 수), `materials:importShared`·`materials:writeFile`·`materials:adoptFile`(파일 이름이 PDF·md일 때 1), `materials:duplicate`(폴더면 그 안의 PDF·md 수).
  - 여러 개 가져오기가 한도를 넘으면 전체를 거부하고 "무료로는 자료를 n개 더 추가할 수 있어요."를 보인다(결정 14-7 권장안).
  - 막지 않는 길: 동기화 적용(채널을 거치지 않는다), 파일 앱으로 넣은 파일(§8.2), PDF 페이지 필기(`pdf:openPageNote`, PDF마다 하나. 열기와 만들기가 같은 채널이라 만들 때만 가려낼 수 없다).
- **세는 법(§8.3)**: 살아 있는 과목과, 살아 있는 과목 안의 PDF·md 중 `cloud_sync_*`의 `origin = 'remote'`(동기화가 만든 것)가 아닌 것.
  - 자료는 `materials_index`로 센다. 세기 전에 살아 있는 과목마다 폴더를 훑어 색인을 디스크에 맞춘다(outbox와 같은 방식). 무료 사용자의 만들기 때만 돈다.
  - 보관한 과목도 센다. 지운 과목과 그 안의 자료는 세지 않는다.
  - 알려진 한계: 다른 Apple ID·다른 제공자로 바꿀 때(`forgetRoot`)와 합치기로 짝지을 때는 받은 것도 `local`이 된다. 그 뒤로는 센다. 잠기는 것은 없다.
  - 프로필마다 따로 센다(자료 저장소가 프로필마다 다르다). AI 횟수는 키체인이라 기기 전체다.
- **AI(부록 B)**: `native:aiRun`(어시스턴트와 학습 생성이 모두 지나는 곳)에서 보내기 전에 검사하고, 답을 받은 요청만 1회로 센다. 실패하거나 취소한 요청은 세지 않는다.
  - 횟수는 키체인(`membership.ai-uses`, 이 기기만)에 `연-월 횟수`로 둔다. 앱을 지웠다 깔아도 남는다. 달은 기기의 현지 달력이다.
- **페이월(§8.4)**: `SubscriptionStoreView`. 가격·기간·무료 체험·자동 갱신 고지·구독 버튼은 시스템이 그린다. 제목은 "반달 플러스"다. 복원 버튼, 약관(Apple 표준 EULA)과 개인정보 처리방침(bandal.io/privacy) 링크를 둔다. 동기화와 다른 결제 수단은 말하지 않는다.
  - 거부된 채널(`PLUS_REQUIRED`)은 `NativeWorkspaceStore.invoke/invokePrivate`가 받아 맨 위 화면에 페이월을 띄운다. 과목 만들기 시트 같은 다른 시트 위에도 뜬다. 같은 사유는 오류 알림으로 다시 보이지 않는다.
  - AI 한도는 AI 서비스가 바로 띄운다(어시스턴트는 저장소 채널을 거치지 않는다).
  - 맨 위에 거부 사유를 띠로 보인다. AI 문구는 "등록한 API 키로 쓰는 AI 기능"이라고 쓴다. 반달이 AI를 제공하는 것으로 읽히지 않게 하기 위해서다.
- **설정 › 구독**: 상태, 이 iPad에서 만든 과목·자료 수와 이번 달 AI 횟수(무료일 때), 반달 플러스 보기, 구매 복원(`AppStore.sync`), 구독 관리(`manageSubscriptionsSheet`). 로그인을 묻지 않는다.
- **스위치**: `NativeReleaseFlags.membership`는 꺼 둔 채 올렸다(11-03 결정, PR #12). 꺼져 있으면 한도, AI 횟수, 페이월, 설정 › 구독이 모두 빠진다. 상품이 ASC에서 준비되고 샌드박스 확인이 끝나면 켠다. 구독을 처음 심사에 내는 빌드는 켠 빌드여야 한다. Debug 빌드는 `--native-membership`으로 켤 수 있고, 페이월 UI 테스트가 이것을 쓴다(§9 "플래그 뒤에서 합친다").
- **옛 서버 판정 결제**: `DesktopBillingService`(`app.bandal.ipad.sync.*`, Supabase 검증)는 `legacyCloudSync`(끔) 뒤에 그대로 둔다. CommonSync와 같은 처리다.
- **테스트**
  - `FreeTierTests`: 과목·자료 한도와 경계, 가져오기 전체 거부, 그림·기타 파일 제외, 폴더 복제, 동기화로 받은 것 제외, 런타임이 채널 전에 검사, AI 월 20회와 달 바뀜.
  - `DesktopAITests`: 보내기 전 검사, 답 받은 요청만 셈, 중지한 요청은 안 셈.
  - `MembershipTests`: Plus 두 상품만 Plus, 환불된 것, 옛 상품(`app.bandal.ipad.sync.*`), 팔지 않는 ID(`app.bandal.ipad.pro.*`)는 무료, 로그인 id만 `appAccountToken`으로. StoreKit 없이 판정 함수와 구매 옵션을 본다.
  - UI 테스트: 무료에서 두 번째 과목이 페이월(사유 띠)을 열고 오류 알림이 없음, 설정 › 구독에서 페이월. UI 테스트는 과목을 여럿 만들므로 `--native-free-tier`를 주지 않으면 Plus로 돈다(DEBUG만).
  - StoreKit Testing(`SKTestSession`)은 단위 테스트에 쓰지 않는다. 같은 프로세스에서 켜면 뒤의 무거운 PDF 테스트 중에 테스트 호스트가 죽었다(전체 실행 3번 모두, 빼면 0번. main도 0번). 이 시뮬레이터에서는 구매 뒤 권한 읽기도 한 번에 3초에서 2분 넘게 멈췄고(`currentEntitlements` 12–37초, `latest(for:)` 160초 넘게), `AppStore.sync()`는 Apple ID 시트를 기다렸다. 그래서 구매·만료·환불·복원은 실기기 샌드박스에서 본다.
- **실기기(샌드박스) 확인**: 체험·구매 → Plus, 구독 관리에서 해지·만료 → 무료(만든 것은 그대로), 구매 복원(반달 로그아웃 상태), 로그인 상태 구매의 `appAccountToken`, 무료 한도 페이월(과목·자료·AI).
- **콘솔에서 할 일(§11)**: `docs/release/app-store-membership.md`에 정리했다. 유료 앱 계약, 그룹과 두 상품(같은 레벨, 가족 공유 끔), 가격, 1주 무료 체험, 설명의 EULA 링크, 심사 메모, 샌드박스 테스터. 구독 때문에 App Privacy 라벨을 바꿀 것은 없다.
- **청구 유예 기간**: 16일(11-03 결정). 갱신 유형은 "모든 갱신", 서버 환경은 "프로덕션 및 Sandbox 환경"으로 정했다. 코드는 바꾸지 않았다. Apple 문서에 따르면 `Transaction.currentEntitlements`에는 `inGracePeriod` 상태의 구독도 들어 있어서, 유예 기간에도 Plus로 본다.

## 부록 L. 스펙 v2.7 "저장소 옮기기"의 iPad 구현 (2026-11-03)

데스크톱 #23(0b94fb5e, SPEC v2.7, 예제 19)과 #24(98d72da7, 11-03 결정)에 맞춘 구현이다. 브랜치는 `feature/sync-v2.7-move`다. 11-02 초안(연결 직전에 `moved_to`를 쓰던 방식)은 버렸다. SPEC은 새 루트의 첫 동기화가 끝난 뒤에 쓴다.

- **데스크톱 #24(98d72da7)로 SPEC에 들어간 것** (11-03 결정, SPEC v2.7 변경 11–13)
  - provider는 `"drive"` 그대로다.
  - `account_hint`(선택): Drive로 옮길 때 그 Google 계정 이메일을 쓴다.
    - 읽을 때는 `@` 하나, 앞뒤가 비지 않음, 공백(U+0020)·제어 문자(Cc) 없음일 때만 받는다(`SyncFormat.accountHint`).
    - 길이 제한은 없다. 데스크톱 정규식이 UTF-16 단위로 읽으므로 iPad는 스칼라 단위로 센다.
    - 틀리면 힌트만 버리고 옮김은 그대로다.
    - `login_hint`와 문구(배너, 앱 안내, 비어 보일 때의 안내)에만 쓴다.
  - `moved_to.t`는 이벤트 시계 `max(지금, clock + 1)`이다. iPad의 clock은 옮기기를 지나 이어지므로, 두 루트와 첫 업로드에 쓴 t가 모두 들어간다.
  - Drive로 따라 옮기는데 새 루트가 비어 보이면, 옮겨 간 계정과 지금 로그인한 계정을 보이고 [Google 계정 다시 고르기]를 둔다. 같은 `login_hint`로 다시 로그인한다(`cloudSync:prepareMove`의 `signInAgain`).
  - Google 계정 바꾸기와 가져오기는 옮기기가 아니다.
- **옮기는 기기** (`CloudSyncService.move`)
  1. 문서를 저장하고 옛 루트와 한 번 더 맞춘다. 그 패스가 `idle`로 끝나지 않았거나 시작한 뒤에 끝난 것이 아니면 옮기지 않는다(`SYNC_MOVE_BEHIND`: 오프라인, 내려오는 파일, 저장 못 한 문서).
  2. 새 저장소를 미리 본다. 다른 기기가 첫 업로드 중이면 기다린다. 아직 내려받는 중이거나 새 형식이면 멈춘다. 살아 있는 과목·문서가 없으면 `upload`, 있으면 `join`이다. 화면이 보여 준 계획(`expect`)과 다르면 멈춘다.
  3. 옛 엔진을 멈춘다. 한 트랜잭션에 `moving {provider, account, at, clock, rebase: true}`을 쓰고, 옛 루트의 자기 파일 기록(`cloud_sync_files`)과 `root_seen`·`device_name`을 지운 뒤 `sync_account`와 provider를 새것으로 바꾼다. 새 엔진을 띄운다.
  4. 새 루트의 첫 패스가 적용 직전에 기준을 맞춘다(`SyncConnection.rebase`, 아래). 빈 루트라면 기준이 모두 지워지고, 첫 업로드의 t는 `moving.clock + 1`부터 차례로 쓴다(`SyncOutbox.asOf`, 표시가 자기 것일 때만).
  5. 새 루트의 패스가 끝날 때마다(`onPass`) `finishMove`가 돈다. 옛 루트를 같은 계정으로 닿을 수 있고 자기 기기 파일이 아직 있으면, 그 파일을 `moved_to`와 함께 다시 쓴다. 쓰기가 실패하면 다음 패스 뒤에 다시 하고, 7일이 지나면 로그(`sync.move code=gave-up`)를 남기고 그만둔다. 옛 쪽이 Drive였으면 그 Google 계정과 내려받은 파일을 지운다(revoke 안 함). 그다음 `moving`을 지운다. "지금 동기화"는 이 단계까지 기다린다.
  - 연결 해제는 끝나지 않은 옮김도 끝낸다. 첫 패스 전이면 `sync_account`를 옛 루트로 되돌린다. 기준이 아직 옛 루트의 것이기 때문이다.
- **기준 맞추기** (`SyncConnection.rebase`, 데스크톱 `connect.ts rebase`의 iPad판)
  - 과목·문서 레지스터는 필드마다, 필기는 개체마다 새 루트와 `(t, device_id)`로 비교한다. 새 루트가 같거나 새로우면 둔다. 오래됐으면 새 루트 값으로 바꾸고, 없으면 지운다. 그러면 이 기기의 값이 새 t로 나간다(떠난 뒤 옛 루트에서 한 삭제 포함).
  - 필기: 없으면 `cloud_sync_objects` 행을 지우고, 오래됐으면 hash만 비운다(stamp는 둬서 더 오래된 원격 필기가 적용되지 않게). 둘 다 dirty로 표시해 export가 비교한다.
  - 노트 내용은 내용으로 본다(`SyncMerge.State.noteHashes`). 기준 `md_hash`가 새 루트의 그 노트 log에 없으면 stamp와 상관없이 기준을 바꾼다. log의 내용이 둘 이상이면 기준 값을 null로 둬 `md_base` 없이 올라가고, 두 내용이 head로 남아 하나가 충돌 사본이 된다.
- **남은 기기**
  - 엔진이 머지한 상태에서 지금 저장소가 아닌 다른 기기의 `moved_to` 가운데 t가 가장 큰 것을 `moved {device, provider, t, account}`로 모든 상태에 싣는다. "나중에"(`cloudSync:dismissMove`, `move_dismissed`)는 그 t까지 감춘다. 기기 이름이 비어 있으면 id 앞 8자다.
  - 설정 › 동기화: 배너 "<기기>에서 Google Drive(이메일)로 옮겼어요" [나중에] [옮기기]. [옮기기]는 한 단계다. Drive 로그인이 없으면 `login_hint`로 로그인하고, 새 루트에 자료가 있으면 바로 옮긴다. 비어 보이면 그 사실과 계획을 보이고 [다시 확인]·[옮기기]를 묻는다. 다른 기기가 아직 올리는 중이면 화면이 열린 동안 30초마다 확인한다.
  - 앱 어디서든 실행마다 옮김 하나에 한 번 아래쪽 안내(`NativeSyncMoveNotice`)가 뜬다. [동기화 설정]은 설정 › 동기화를 연다.
- **설정 화면**: "저장소 옮기기" 카드에서 계획을 먼저 보이고 옮긴다. 켜진 상태에서 위쪽 선택기로 다른 저장소를 골라도 같은 흐름이다. 옮기는 동안에는 "Google Drive로 옮기는 중이에요. 다 올리면 iCloud에 알리고 연결을 끊어요."가 보인다. "고급"을 펴면 연결 해제와 그 설명이 있다. 다른 Google 계정으로 바꾸거나(c) 가져오기를 할 때(d)는 연결 해제 뒤 새로 연결한다. 둘 다 옮김이 아니라 `moved_to`를 쓰지 않는다.
- **테스트** (`CloudSyncConnectTests`)
  - 빈 Drive로 옮기기: 첫 업로드의 t, 옛 iCloud의 `moved_to`와 `account_hint`, 따라오는 기기에게 보이는 배너와 `login_hint`, 다시 올라가지 않는 문서, 새 과목 하나만 올라가는지
  - 떠난 뒤 옛 루트에서 한 이름 바꾸기와 삭제가 이김, "나중에"
  - 마지막 패스가 끝나지 않으면 옮기지 않음
  - 양쪽에서 고친 노트는 둘 다 남음
  - 떠났던 저장소로 돌아오기: 자기 `moved_to`는 안내가 아니고 다시 쓰이며 빠짐, 남겨 둔 Drive에 알린 뒤 Google 계정을 지움
  - 옛 루트에 알리기는 다시 시도하다 일주일 뒤 그만둠
  - `SyncFormatTests`(읽기 규칙, 힌트)와 `SyncConformanceTests`(예제 19, `moved_to` 투영)
