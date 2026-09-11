# 아키텍처

시스템을 이렇게 나눈 이유와, 나중에 바뀔 가능성이 높은 부분을 어떻게 격리했는지 정리한다.

<br>

## 1. 서비스 경계

### 왜 셋인가

| 서비스 | 아는 것 | 모르는 것 |
|---|---|---|
| config.server | 각 서비스가 어떤 설정을 쓰는지 | 그 설정으로 무엇을 하는지 |
| backend | 문서를 **어떻게** 처리하는지 (엔진, 스토리지, DB) | **언제** 처리해야 하는지 |
| scheduler | **언제** 처리할지 | 어떻게 처리하는지 |

이 분담의 핵심은 **scheduler 가 OCR 을 모른다**는 점이다.
스케줄러는 backend 의 내부 API 를 때리는 얇은 트리거일 뿐이다.

그래서:

- Tesseract 네이티브 라이브러리는 backend 이미지에만 필요하다
- 처리량이 부족하면 backend 만 늘린다. 스케줄러는 한 대로 충분하다
- OCR 엔진을 바꿔도 스케줄러는 손댈 일이 없다

반대로 스케줄러에 로직이 쌓이기 시작하면 이 분리는 의미를 잃는다.
**스케줄러는 얇게 유지한다**는 것이 유지해야 할 제약이다.

### 왜 OCR 실행을 스케줄러에 두지 않았나

스케줄러가 직접 OCR 을 돌리면 엔진 의존성과 스토리지 접근이 두 서비스로 퍼진다.
그러면 엔진을 교체할 때 두 곳을 고쳐야 하고, 스케일아웃 단위도 뒤섞인다.

<br>

## 2. 바뀔 것을 포트로 끊기

초기 구조에서 가장 확실한 것은 **나중에 바뀐다**는 사실이다.
OCR 엔진과 스토리지가 특히 그렇다. 둘 다 인터페이스로 끊어두었다.

```java
public interface OcrEngine {
    String name();
    OcrExtraction extract(OcrDocumentSource source);
}

public interface DocumentStorage {
    String store(String originalFilename, byte[] content);
    byte[] read(String storageKey);
    void delete(String storageKey);
    boolean exists(String storageKey);
}
```

### 설계상 의도

**`DocumentStorage.store()` 가 경로가 아니라 "스토리지 키"를 돌려준다.**
로컬 FS 에서는 상대 경로지만 S3 에서는 오브젝트 키가 된다. 도메인은 그 차이를 모른다.

**`OcrEngine` 이 `Path` 가 아니라 `byte[]` 를 받는다.**
스토리지가 로컬이든 객체 스토리지든 엔진은 바이트만 보면 되게 한 단계 끊어둔 것이다.
대신 파일 전체가 메모리에 올라간다 — 업로드 크기를 20MB 로 제한해 막고 있고,
그 이상을 다루려면 스트리밍으로 바꿔야 한다.

### 엔진 교체

`ocr.engine.type` 설정 하나로 바뀐다.

| 값 | 구현 | 용도 |
|---|---|---|
| `tesseract` | `TesseractOcrEngine` | 기본. 네이티브 tesseract + tessdata 필요 |
| `stub` | `StubOcrEngine` | 네이티브가 없는 로컬/CI. 인식 없이 파이프라인만 돌린다 |

stub 엔진이 있어서 **외부 의존 없이 파이프라인 전체를 테스트할 수 있다.**
통합 테스트가 이 엔진으로 돈다.

<br>

## 3. 문서 상태 머신

```
PENDING ──startProcessing──▶ PROCESSING ──completeWith──▶ COMPLETED
   ▲                              │
   │                              └──fail──▶ FAILED (재시도 한도 소진)
   └──────────────────────────────┘
        재시도 여유가 남아 있으면 PENDING 으로 되돌아간다
```

상태 전이 규칙은 **서비스가 아니라 `Document` 도메인이 지킨다.**
setter 를 두지 않고 `startProcessing()`, `completeWith()`, `fail()` 같은
의미 있는 메서드로만 상태를 바꾼다. "PROCESSING 이 아닌데 완료 처리" 같은
잘못된 전이는 도메인이 `IllegalStateException` 으로 막는다.

### 정체(stalled) 문서 회수

backend 인스턴스가 OCR 처리 도중 죽으면 문서는 `PROCESSING` 에 남는다.
아무도 손대지 않으면 **영영 처리되지 않는다.**

스케줄러의 회수 잡이 일정 시간(`ocr.processing.stale-after-minutes`)이 지난
`PROCESSING` 문서를 `PENDING` 으로 돌려놓는다. 눈에 덜 띄지만 파이프라인이
막히지 않게 하는 것은 이쪽이다.

지금은 **시간 기준뿐**이라 처리가 오래 걸리는 정상 문서도 회수될 수 있다.
정확히 하려면 처리 중 heartbeat 갱신이 필요하다.

<br>

## 4. 트랜잭션 전략

OCR 은 수 초에서 수십 초가 걸린다. 한 트랜잭션 안에서 돌리면 **커넥션 풀이 금방 마른다.**

그래서 상태 전이와 OCR 실행을 나눴다.

```
claim()      ── 짧은 트랜잭션 ── PENDING → PROCESSING
submit()     ── 워커 풀에 위임 → 여기서 HTTP 응답(202)이 나간다
extract()    ── 워커 스레드, 트랜잭션 밖 ── 느린 작업
complete()   ── 짧은 트랜잭션 ── PROCESSING → COMPLETED
```

접수와 처리를 나눈 것이 핵심이다. 동기로 끝까지 처리하면 `배치 크기 × 건당 소요` 가
호출자(스케줄러)의 읽기 타임아웃을 넘고, 요청이 끊긴 뒤에도 처리는 계속 돌아
다음 주기 요청과 겹친다. **바운드 큐 + `AbortPolicy`** 가 백프레셔 역할을 하고,
큐에 넣지 못한 문서는 `releaseClaim()` 으로 되돌린다 — `fail()` 과 달리 재시도 횟수를
올리지 않으므로 큐가 붐빌 때마다 멀쩡한 문서가 `FAILED` 로 밀려나지 않는다.

| 클래스 | 트랜잭션 | 역할 |
|---|---|---|
| `DocumentApplicationService` | 있음 | 등록·조회. 짧고 단순 |
| `DocumentProcessingService` | **없음** | 선점 → 워커 풀 위임 순서만 잡는다 |
| `DocumentTransitionService` | `REQUIRES_NEW` | 상태 전이만 |

전이 메서드를 `DocumentProcessingService` 안에 두지 않은 이유:
**같은 클래스 안에서 호출하면 프록시를 타지 않아 트랜잭션이 분리되지 않는다.**
별도 빈이어야 의도한 대로 동작한다.

### 실패해도 문서는 반드시 정리된다

`runOcr()` 은 어떤 예외가 나든 잡아서 `fail()` 을 호출한다.
여기서 예외가 새어나가면 문서가 `PROCESSING` 에 영영 남기 때문이다.
실패 기록마저 실패하면 로그만 남기고 회수 잡에 맡긴다.

<br>

## 5. 동시성

스케줄러나 backend 를 여러 대 띄우면 **같은 문서를 동시에 집을 수 있다.**

`Document` 에 `@Version` 낙관적 락을 걸어두었다. 선점 경쟁에서 진 쪽은
`OptimisticLockingFailureException` 을 받고 조용히 건너뛴다
(`ProcessingSummary.skipped` 로 집계된다).

다만 이것은 **문서 중복 처리만** 막는다. 스케줄러를 여러 대 띄우면
불필요한 호출이 배수로 늘어난다. 분산 락(ShedLock)이 필요한 이유다.

<br>

## 6. 설정 관리

포트, DB, 스토리지 경로, 엔진 종류, 잡 주기 — 모두 설정 서버가 내려준다.
각 서비스의 `application.yml` 에는 **"설정 서버를 어떻게 찾을지"만** 있다.

```yaml
spring:
  application:
    name: ocr-backend          # 설정 서버가 ocr-backend.yml 을 찾는 기준
  config:
    import: "configserver:${CONFIG_SERVER_URL:http://localhost:8888}"
  cloud:
    config:
      fail-fast: true          # 설정을 못 받으면 기동 실패
```

`fail-fast: true` 로 둔 이유: 설정을 못 받았는데 **잘못된 기본값으로 조용히 뜨는 것**이
설정 서버 장애보다 위험하다. 대신 재시도를 붙여 기동 순서 문제는 흡수한다.

`spring.application.name` 이 곧 설정 파일 이름이다. 바꾸면 설정을 못 받는다.

<br>

## 7. 스키마 관리

스키마 출처는 **Flyway 하나**다. JPA 는 `ddl-auto: validate` 만 한다.

`local` 프로파일(H2)도 마찬가지다. H2 를 `MODE=PostgreSQL` 로 띄우고 같은
마이그레이션을 돌린다. 그래서 **엔티티와 마이그레이션이 어긋나면 로컬과 테스트에서
먼저 드러난다.** 운영에서 처음 알게 되는 일이 없도록 한 배치다.

`OcrResult` 를 별도 테이블이 아니라 `@Embeddable` 로 둔 이유:
결과가 문서당 하나뿐이라 조인할 이유가 없다.

<br>

## 8. 지금 비어 있는 것

의도적으로 넣지 않았다. 각각이 별도 작업 단위다.

| 항목 | 영향 | 우선순위 |
|---|---|---|
| 인증·인가 | `/internal` API 가 열려 있어 외부에서 배치를 돌릴 수 있다 | 높음 |
| 설정 값 암호화 | 설정 서버가 뚫리면 DB 접속 정보가 그대로 노출된다 | 높음 |
| 파일 내용 검증 | `Content-Type` 헤더만 믿는다. 확장자만 바꾼 파일이 통과한다 | 높음 |
| 분산 락 | 스케줄러 다중화 시 잡이 중복 실행된다 | 중간 |
| 컨테이너 이미지 | 배포 단위가 없다 | 중간 |
| 문서 보관 정책 | 원본 파일이 무한히 쌓인다 | 중간 |
| 스토리지 스케일아웃 | 로컬 FS 라 backend 다중화 시 파일을 공유하지 못한다 | 중간 |
| 관측성 | 잡 실행 이력과 메트릭이 없다 | 낮음 |
