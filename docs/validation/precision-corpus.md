# Precision corpus

Pinned open-source projects scanned nightly (`corpus/projects.json`), with canonical findings
committed under `corpus/expected/`. Every analysis change re-scans the corpus and adjudicates each
changed row here before `corpus/accept.sh` records it.

## Scorecard

| Project | Findings | Sampled | True positives | False positives | Precision | Adjudicated on |
| --- | --- | --- | --- | --- | --- | --- |
| Alamofire | 124 | 30 | 20 | 10 | 66.7 % | 2026-09-27 |
| swift-nio | 434 | 30 | 22 | 8 | 73.3 % | 2026-09-27 |
| Wikipedia iOS | 3,189 | 30 | 24 | 6 | 80.0 % | 2026-09-27 |
| **All** | 3,747 | 90 | 66 | 24 | **73.3 %** | |

Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.0, arm64 macOS 27.0. Findings from
Lethen `bc8c5b5` (analysis unchanged in `08a45bc`), the commits that generated the expectations.
Alamofire at `bda9ed5` and swift-nio at `feaf4ac` are libraries, scanned with `--retain-public`.
Wikipedia iOS at `599e4a6` is an app, scanned with `--project Wikipedia.xcodeproj --schemes
Wikipedia` for the generic iOS Simulator destination.

The Phase 2 target is 95 %. This first measurement is the baseline the analysis changes are
judged against; the false-positive classes below say what each fix must remove.

## Adjudication

Verdicts: TP (dead, safe to remove), FP (used in a way Lethen cannot see; say how), UNSURE.
Seed 2026, `corpus/sample.py <project>`. A finding is TP only when acting on its hint is safe on
every platform and build configuration the project supports, so a parameter whose signature is
fixed by a protocol requirement, an override, or a function type is FP. Precision is
TP / (TP + FP), leaving UNSURE out of both; there were no UNSURE verdicts.

| ID | Location | Declaration | Hints | Verdict | Evidence |
| --- | --- | --- | --- | --- | --- |
| Alamofire-1 | `Source/Core/WebSocketRequest.swift:407` | var.parameter `type` | unused | FP | Public metatype type-witness parameter (`_ type: Value.Type = Value.self`) of public `streamDecodableEvents`; callers pass it to bind the generic (Tests/WebSocketTests.swift:146, Source/Features/Concurrency.swift:808 and :824), so removing it breaks public API and those call sites. |
| Alamofire-2 | `Source/Features/OfflineRetrier.swift:237` | function.method.static `offlineRetrier(monitor:maximumWait:)` | unused | TP | Internal static factory with no callers anywhere (rg `offlineRetrier(` only hits declarations at OfflineRetrier.swift:194/211/229/237); tests construct `OfflineRetrier(monitor:maximumWait:)` directly (Tests/OfflineRetrierTests.swift:22 etc.). |
| Alamofire-3 | `Tests/AFError+AlamofireTests.swift:360` | var.instance `isRevocationPolicyCreationFailed` | unused | TP | Test helper on `AFError.ServerTrustFailureReason`; only occurrence of the name in the checkout is its declaration. |
| Alamofire-4 | `Tests/AFError+AlamofireTests.swift:385` | var.instance `isCertificatePinningFailed` | unused | TP | Test helper on `AFError.ServerTrustFailureReason`; only occurrence of the name in the checkout is its declaration. |
| Alamofire-5 | `Tests/BaseTestCase.swift:69` | var.instance `session` | assignOnlyProperty | FP | Written by `stored(_:)` (BaseTestCase.swift:109) and cleared in `tearDown` (:82) to hold a strong reference to each test's `Session` for the whole test; `Session.deinit` finishes active requests with `.sessionDeinitialized` (Source/Core/Session.swift:235-239), so removing this keep-alive owner changes behavior once the local `let session = stored(...)` is released after last use. |
| Alamofire-6 | `Tests/SessionTests.swift:112` | var.instance `retryErrors` | unused | TP | Computed accessor on the test `RequestHandler`; no reader anywhere (rg `retryErrors` only hits the backing state at :96/:175 and the separate copy at :198/:207/:235), and `RequestInterceptor` has no such requirement. |
| Alamofire-7 | `Source/Core/WebSocketRequest.swift:122` | var.instance `latency` | assignOnlyProperty | TP | Internal `let` on public `PingResponse.Pong`, set only via memberwise init at WebSocketRequest.swift:297 and never read in Source or Tests (tests only check `receivedPong` non-nil, WebSocketTests.swift:446); not public, so no external reader. |
| Alamofire-8 | `Tests/TLSEvaluationTests.swift:160` | function.method.instance `disabled_testRevokedCertificateRequestBehaviorWithDefaultServerTrustPolicy()` | unused | TP | Deliberately disabled test (no `test` prefix, so XCTest never discovers it) with no callers; removal is behavior-safe, though authors keep it "for debugging purposes" (comment at TLSEvaluationTests.swift:96-97). |
| Alamofire-9 | `Source/Features/Combine.swift:461` | typealias `Failure` | unused | TP | Typealias inside `private final class Inner: Subscription`; `Subscription` has no `Failure` associated type and nothing in `Inner` (Combine.swift:459-489) references `Failure`. |
| Alamofire-10 | `Tests/TLSEvaluationTests.swift:95` | function.method.instance `disabled_testRevokedCertificateRequestBehaviorWithNoServerTrustPolicy()` | unused | TP | Deliberately disabled test (not XCTest-discoverable) with no callers anywhere; comment at TLSEvaluationTests.swift:96-97 says it is kept only for debugging. |
| Alamofire-11 | `Tests/AuthenticationInterceptorTests.swift:35` | var.instance `userID` | assignOnlyProperty | TP | `TestCredential.userID` is only assigned (init at :47, fixture args at :91/:517/:553) and never read; `AuthenticationCredential` only requires `requiresRefresh`, and the struct is not Equatable/Codable. |
| Alamofire-12 | `Tests/AuthenticationInterceptorTests.swift:82` | var.parameter `session` | unused | FP | `refresh(_:for:completion:)` is the witness for public protocol requirement `Authenticator.refresh(_:for:completion:)` (Source/Features/AuthenticationInterceptor.swift:84, no default impl); signature is fixed. |
| Alamofire-13 | `Tests/AFError+AlamofireTests.swift:83` | var.instance `isOutputStreamCreationFailed` | unused | TP | `AFError.isOutputStreamCreationFailed` test helper; no reader of the `AFError` member anywhere (only the reason-level member at :242 is read, by this very helper at :84). |
| Alamofire-14 | `Tests/AFError+AlamofireTests.swift:242` | var.instance `isOutputStreamCreationFailed` | unused | TP | `MultipartEncodingFailureReason.isOutputStreamCreationFailed` is read only at :84 inside the unused `AFError` helper (row 13); dead once that is removed. |
| Alamofire-15 | `Tests/ParameterEncoderTests.swift:1131` | var.instance `four` | unused | FP | Stored property of `private struct EncodableStruct: Encodable` read by the synthesized `encode(to:)`; tests encode it and assert the key is present (`four%5B%5D=1...` at ParameterEncoderTests.swift:423, :474, :562). |
| Alamofire-16 | `Tests/AuthenticationInterceptorTests.swift:105` | var.parameter `urlRequest` | unused | FP | `didRequest(_:with:failDueToAuthenticationError:)` witnesses public protocol requirement `Authenticator.didRequest` (Source/Features/AuthenticationInterceptor.swift:109, no default impl); parameter cannot be removed. |
| Alamofire-17 | `Tests/AFError+AlamofireTests.swift:78` | var.instance `isBodyPartInputStreamCreationFailed` | unused | TP | `AFError.isBodyPartInputStreamCreationFailed` test helper; the name only appears at its declaration and at the reason-level member it forwards to (:79, :237). |
| Alamofire-18 | `Tests/NSLoggingEventMonitor.swift:223` | var.parameter `temporaryURL` | unused | TP | The method is a stale near-miss of `EventMonitor.request(_:didValidateRequest:response:fileURL:withResult:)` (Source/Features/EventMonitor.swift:212-216), so it witnesses no requirement and has no callers; the parameter is genuinely unused (really the whole method is dead). |
| Alamofire-19 | `Tests/ParameterEncoderTests.swift:1130` | var.instance `three` | unused | FP | Encoded by synthesized `Encodable` of `EncodableStruct`; tests assert `three=1` in the output (ParameterEncoderTests.swift:423, :474, :562). |
| Alamofire-20 | `Tests/ParameterEncoderTests.swift:1129` | var.instance `two` | unused | FP | Encoded by synthesized `Encodable` of `EncodableStruct`; tests assert `two=2` in the output (ParameterEncoderTests.swift:423, :474, :562). |
| Alamofire-21 | `Tests/AFError+AlamofireTests.swift:350` | var.instance `isNoPublicKeysFound` | unused | TP | Test helper on `AFError.ServerTrustFailureReason`; only occurrence of the name in the checkout is its declaration. |
| Alamofire-22 | `Tests/NSLoggingEventMonitor.swift:223` | var.parameter `response` | unused | TP | Same stale non-witness method as row 18 (protocol now uses `fileURL:`, EventMonitor.swift:212-216); no callers, body only logs `request` and `result`. |
| Alamofire-23 | `Tests/ParameterEncoderTests.swift:1137` | struct `NestedEncodableStruct` | unused | FP | Instantiated as the value of `EncodableStruct.seven` (ParameterEncoderTests.swift:1134), which synthesized `Encodable` encodes; tests assert `seven%5Ba%5D=a` (:423, :474, :562). Reported only as a cascade of the false `seven` finding. |
| Alamofire-24 | `Tests/AuthenticationInterceptorTests.swift:34` | var.instance `refreshToken` | assignOnlyProperty | TP | `TestCredential.refreshToken` is only assigned (init at :46, fixture args at :90/:516/:552) and never read; the type is not Codable/Equatable and no protocol requires it. |
| Alamofire-25 | `Tests/AFError+AlamofireTests.swift:31` | var.instance `isMissingURLFailed` | unused | TP | Test helper on `AFError`; only occurrence of the name in the checkout is its declaration. |
| Alamofire-26 | `Source/Features/Combine.swift:616` | var.parameter `type` | unused | FP | Public metatype type-witness parameter of `DownloadRequest.publishDecodable(type:...)`; callers pass it to bind `T` (Tests/CombineTests.swift:1047, :1070, :1212; Documentation/AdvancedUsage.md:1321), so it is public API that cannot be removed. |
| Alamofire-27 | `Source/Core/AFError.swift:619` | var.instance `output` | unused | TP | Internal computed `ServerTrustFailureReason.output`; no `.output` read anywhere in Source or Tests (rg), unlike its sibling accessors. |
| Alamofire-28 | `Tests/AuthenticationInterceptorTests.swift:81` | var.parameter `credential` | unused | FP | Witness for public protocol requirement `Authenticator.refresh(_:for:completion:)` (Source/Features/AuthenticationInterceptor.swift:84); signature is fixed, and the documented example conformance uses the parameter (Documentation/AdvancedUsage.md:737). |
| Alamofire-29 | `Source/Core/RequestTaskMap.swift:96` | var.instance `eventCount` | unused | TP | Internal computed property; the name only occurs at its declaration and in its own precondition message (RequestTaskMap.swift:96-97). |
| Alamofire-30 | `Source/Core/WebSocketRequest.swift:330` | function.method.instance `startAutomaticPing(every:)` | unused | TP | The `Duration` overload has no callers; every call site passes the `TimeInterval` from `configuration.pingInterval` (WebSocketRequest.swift:274, :320), and the `Duration` overload only forwards to it (:332). |
| swift-nio-1 | `Sources/NIOCore/ByteBuffer-views.swift:163` | var.parameter `bounds` | unused | FP | `_failEarlyRangeCheck(_:bounds:)` (Range overload) is a stdlib `Collection` requirement that `ByteBufferView` witnesses as an intentional no-op (comment at ByteBuffer-views.swift:155); the signature is fixed by the protocol and is also public API. |
| swift-nio-2 | `Sources/NIOHTTP1/NIOHTTPObjectAggregator.swift:243` | var.parameter `context` | unused | TP | Private `beginAggregation(context:request:message:)` (NIOHTTPObjectAggregator.swift:242-252) never reads `context`; it is not a protocol witness or override. |
| swift-nio-3 | `Sources/NIOWebSocket/NIOWebSocketServerUpgrader.swift:271` | var.parameter `initialResponseHeaders` | unused | TP | Private free function `_buildUpgradeResponse` (NIOWebSocketServerUpgrader.swift:268-311) never reads `initialResponseHeaders`; it only builds headers from `shouldUpgrade`'s result. Callers at :165 and :249 would need the argument dropped. |
| swift-nio-4 | `Sources/_NIODataStructures/Heap.swift:274` | function.method.instance `index(after:)` | unused | TP | Internal `Heap` conforms only to `Sequence` (Heap.swift:247), which has no `index(after:)` requirement; no caller anywhere in the checkout (leftover from the Collection-era code inlined in c9c39742). |
| swift-nio-5 | `Tests/NIOFSTests/Internal/MockingInfrastructure.swift:73` | function.method.instance `expectEqual(_:_:_:)` | unused | TP | `TestCase.expectEqual` extension helper is not a protocol requirement (requirements at :46-57) and `expectEqual` has no call site anywhere in the checkout (only `expectEqualSequence` at :63 is a different function). |
| swift-nio-6 | `Sources/NIOCore/ByteBuffer-multi-int.swift:658` | var.parameter `as` | unused | FP | Public `getMultipleIntegers(at:endianness:as:)` uses `as: (T1...T6).Type = (...).self` as a type-selection metatype parameter: callers pass it to pick the generic types (e.g. ByteBuffer-multi-int.swift:24 forwards its own `as` argument, Tests/NIOCoreTests/ByteBufferTest.swift:3748 passes `as: (UInt8, UInt8).self`). Its value is intentionally unread but it is public API and drives inference. |
| swift-nio-7 | `Sources/NIOCore/IntegerTypes.swift:79` | var.static `bitWidth` | unused | TP | `_UInt56` (IntegerTypes.swift:71) conforms to no protocol requiring `bitWidth` (not FixedWidthInteger); the only `.bitWidth` reads in NIOCore are on FixedWidthInteger generics (IntegerBitPacking.swift:35/55, ByteBuffer-int.swift:142/152). Tests use only `.max/.min/.description`. |
| swift-nio-8 | `Tests/NIOCoreTests/XCTest+AsyncAwait.swift:73` | function.free `XCTAssertNoThrowWithResult(_:file:line:)` | unused | TP | Internal test helper with no call site anywhere in the checkout; the other two copies (Tests/NIOEmbeddedTests/XCTest+AsyncAwait.swift:60, Tests/NIOPosixTests/XCTest+AsyncAwait.swift:72) are separate module-local declarations and are also uncalled. |
| swift-nio-9 | `Tests/NIOFSIntegrationTests/FileSystemTests.swift:924` | var.parameter `line` | unused | TP | Idiomatic but unused: private `testCopyCancelledPartWayThrough(_:line:)` (FileSystemTests.swift:922-984) never reads `line`, no `#if` in the body, and no caller passes `line:`. |
| swift-nio-10 | `Sources/_NIOFileSystem/Internal/System Calls/Mocking.swift:347` | function.method.instance `_withPlatformString(_:)` | unused | TP | Internal `String._withPlatformString` has no caller anywhere in the checkout (including `#if ENABLE_MOCKING` blocks and the Windows branch inside it); the NIOFS copy at Sources/NIOFS/Internal/System Calls/Mocking.swift:347 is likewise uncalled. |
| swift-nio-11 | `Sources/NIOPosix/PendingWritesManager.swift:621` | var.instance `isEmpty` | unused | TP | Requirement of internal protocol `PendingWritesManager` is never read through the protocol (the only protocol extension, :646-689, doesn't use it, and nothing is generic over the protocol); conformers' own `isEmpty` (:359, PendingDatagramWritesManager.swift) are read on concrete types (SocketChannel.swift:763, BaseStreamSocketChannel.swift:45), so dropping the requirement is safe. |
| swift-nio-12 | `Tests/NIOPosixTests/SyscallAbstractionLayer.swift:654` | var.parameter `file` | unused | TP | Idiomatic but unused: private `makeServerSocketChannel(eventLoop:file:line:)` (:652-675) never reads `file`; callers (:711, :761) would just drop the argument. |
| swift-nio-13 | `Tests/NIOCoreTests/ByteBufferTest.swift:3448` | var.parameter `size` | unused | TP | `testAllocationOfReallyBigByteBuffer_mallocHook(_:)` ignores `size` (returns `malloc(16)`), and it is only invoked from a wrapping closure `{ testAllocationOfReallyBigByteBuffer_mallocHook($0) }` at ByteBufferTest.swift:1405, so the signature is not pinned by a function type (malloc-shaped by convention only). |
| swift-nio-14 | `Sources/_NIOFileSystem/Internal/System Calls/Mocking.swift:318` | function.free `system_strlen(_:)` | unused | TP | The `UnsafePointer<CChar>` overload of `system_strlen` has no caller anywhere in the checkout (grep finds only the declarations in _NIOFileSystem and NIOFS Mocking.swift); code uses `system_platform_strlen` instead. |
| swift-nio-15 | `Tests/NIOTestUtilsTests/NIOHTTP1TestServerTest.swift:49` | function.constructor `init(_:)` | unused | TP | The throwing `SendableRequestPart.init(_: HTTPClientRequestPart)` is never called: only the reverse `HTTPClientRequestPart.init(_:)` (:36) is used, via `.init(response)` at :74; no `try .init(`/`try HTTPServerRequestPart(` in the module. |
| swift-nio-16 | `Tests/NIOPosixTests/CodecTest.swift:63` | typealias `InboundIn` | unused | TP | `ByteToInt32Decoder` conforms only to `ByteToMessageDecoder`, which declares `InboundOut` but no `InboundIn` associated type (Sources/NIOCore/Codec.swift:143-145); nothing references `ByteToInt32Decoder.InboundIn`. |
| swift-nio-17 | `Tests/NIOPosixTests/SyscallAbstractionLayer.swift:628` | var.parameter `eventLoop` | unused | TP | In private `makeSocketChannel(eventLoop:file:line:)` the body's `eventLoop` refers to the shadowing closure parameter of `runSALOnEventLoop { eventLoop, ... }` (:632), so the function parameter is never read. |
| swift-nio-18 | `Tests/NIOPosixTests/SyscallAbstractionLayer.swift:1139` | function.method.instance `assertSyscallAndReturn(_:file:line:matcher:)` | unused | TP | `SyscallAssertions.assertSyscallAndReturn` (struct at :808) has no caller; every `selector.assertSyscallAndReturn(...)` call (:824, :855, ...) resolves to `HookedSelector.assertSyscallAndReturn` at :568 (`selector` is a `HookedSelector`, :812). |
| swift-nio-19 | `Sources/NIOPosix/ThreadPosix.swift:233` | function.method.static `compareThreads(_:_:)` | unused | TP | No call of `compareThreads` exists on any platform: grep finds only the `ThreadOps` requirement (Thread.swift:39) and the Posix/Windows witnesses (ThreadPosix.swift:233, ThreadWindows.swift:150). Acting on it needs the requirement and the Windows witness deleted too, and Lethen did not report the requirement at Thread.swift:39. |
| swift-nio-20 | `Tests/NIOPosixTests/NIOLoopBoundTests.swift:146` | var.parameter `sendableThing` | unused | FP | `sendableBlackhole<S: Sendable>(_ sendableThing: S) {}` is a compile-time Sendable assertion: the parameter exists only so the argument's type is checked against `S: Sendable` (calls at NIOLoopBoundTests.swift:31-32). Removing it removes the check. |
| swift-nio-21 | `Tests/NIOPosixTests/SyscallAbstractionLayer.swift:215` | var.instance `syscall` | assignOnlyProperty | FP | Diagnostic payload of `UnexpectedSyscall: Error`, thrown at SyscallAbstractionLayer.swift:579. XCTest prints the caught error with `String(describing:)`, which reads stored properties by reflection (Mirror), so the value is read in failure messages. |
| swift-nio-22 | `Tests/NIOCoreTests/ByteBufferTest.swift:3494` | var.parameter `count` | unused | FP | `testReserveCapacityLarger_memcpyHook` is passed as a function value (`copy: testReserveCapacityLarger_memcpyHook` at ByteBufferTest.swift:2525 and :2547), so its signature is fixed by `ByteBufferAllocator`'s `copy` function type (Sources/NIOCore/ByteBuffer-core.swift:184). |
| swift-nio-23 | `Sources/NIOPosix/SelectableChannel.swift:27` | associatedtype `SelectableType` | unused | TP | `SelectableChannel.SelectableType` is never referenced. `SocketType.SelectableType` at BaseSocketChannel.swift:274 refers to the separate `BaseSocketProtocol.SelectableType` (SocketProtocols.swift:24), and no generic code uses `SelectableChannel`'s associated type. |
| swift-nio-24 | `Sources/NIOCore/SocketAddresses.swift:808` | protocol `SockAddrProtocol` | redundantConformance | TP | `SockAddrProtocol` (SocketAddresses.swift:751) is never used as a type, constraint or existential anywhere in the checkout (grep finds only the declaration and four conformances), so `sockaddr_un`'s conformance can go; `withSockAddr` stays callable on the concrete type. |
| swift-nio-25 | `Sources/NIOCore/AsyncAwaitSupport.swift:40` | function.free `withNIOUnsafeThrowingContinuation(isolation:_:)` | unused | FP | Compiler-version-conditional use: the `nonisolated(nonsending)` overload (:28) exists only under `#if compiler(>=6.2)`. On Swift 6.1, the package's supported minimum (Package.swift `swift-tools-version:6.1`, README.md:93), this `isolation:` overload is the only one, and it is what NIOAsyncWriter.swift:580/690 and NIOThrowingAsyncSequenceProducer.swift:637 call. |
| swift-nio-26 | `Tests/NIOFSIntegrationTests/FileSystemTests.swift:1071` | var.parameter `line` | unused | TP | Idiomatic but unused: private `testCopyNonExistentFile(_:line:)` (FileSystemTests.swift:1069-1080) never reads `line` and no caller passes it. |
| swift-nio-27 | `Sources/NIOCore/ByteBuffer-multi-int.swift:2617` | var.parameter `as` | unused | FP | Same as swift-nio-6: public `getMultipleIntegers` 13-tuple overload's `as: (T1...T13).Type = (...).self` is a type-selection metatype parameter forwarded by `readMultipleIntegers(endianness:as:)` and passed by callers, so it is public API that drives generic inference. |
| swift-nio-28 | `Sources/NIOCore/ByteBuffer-views.swift:157` | var.parameter `bounds` | unused | FP | Same as swift-nio-1: `_failEarlyRangeCheck(_ index:bounds: Range<Index>)` witnesses the stdlib `Collection` requirement as a deliberate no-op (comment at ByteBuffer-views.swift:155); the signature is fixed and public. |
| swift-nio-29 | `Sources/NIOFS/Internal/System Calls/Mocking.swift:314` | function.free `system_strerror(_:)` | unused | TP | Internal `system_strerror` has no caller anywhere in the checkout, on any platform branch (grep finds only this declaration and the identical one in _NIOFileSystem). |
| swift-nio-30 | `Tests/NIOPosixTests/TestUtils.swift:728` | var.parameter `line` | unused | TP | Idiomatic but unused: `withTCPServerChannel(bindTarget:group:file:line:_:)` (TestUtils.swift:724-742) never reads `line` (or `file`), and no caller passes `line:`. |
| wikipedia-ios-1 | `WMFComponents/Sources/WMFComponents/Components/ArticlePreview/WMFArticlePreviewViewModel.swift:8` | var.instance `imageURL` | redundantPublicAccessibility | TP | All `WMFArticlePreviewViewModel` construction and reads are inside the WMFComponents package (WMFArticlePreviewView.swift:6, WMFHistoryView.swift:166, WMFSearchResultsViewModel.swift:262, WMFAsyncPageRowSaved.swift:326). No other target or package refers to the type or `.imageURL`, so `public` can be dropped. |
| wikipedia-ios-2 | `WMFData/Sources/WMFDataMocks/WMFMockGrowthTasksService.swift:2` | module `WMFData` | unused | FP | The whole file body is inside `#if DEBUG` (lines 4-135) and uses `WMFData.WMFServiceRequest` (line 6) and `WMFService` (line 49). The scan built the scheme's Test action configuration ("Test": `-DNDEBUG -DTEST`, project.pbxproj:12186), where DEBUG is off and the block is empty. Removing the import breaks the Debug build. |
| wikipedia-ios-3 | `Wikipedia/Code/ImageRecommendationsFunnel.swift:279` | function.method.instance `logSettingsDidDisableSuggestedEditsCard()` | unused | TP | The only occurrence of the name in the checkout is the declaration. The method is not `@objc`, and `ImageRecommendationsFunnel` (line 3) is not `@objcMembers`, so Objective-C cannot reach it. Callers use `logSettingsToggleSuggestedEditsCard(isOn:)` (line 274) instead. |
| wikipedia-ios-4 | `Wikipedia/Code/InsertMediaSelectedImageViewController.swift:59` | var.parameter `insertMediaSearchResultsCollectionViewController` | unused | TP | This is the only conformer of the project-internal `InsertMediaSearchResultsCollectionViewControllerDelegate` (InsertMediaSearchResultsCollectionViewController.swift:41), and its body never uses the sender. Lethen also reports the requirement's parameter (42:70). Caveat: the parameter can only be removed together with the requirement and the call sites at lines 251 and 281. |
| wikipedia-ios-5 | `Wikipedia/Code/SizeThatFitsReusableView.swift:67` | function.method.instance `layoutSubviews()` | redundantPublicAccessibility | TP | The enclosing `class SizeThatFitsReusableView` (line 6) is internal, so `public` on this `final override` has no effect. An internal override of a UIKit method in an internal class is legal. The file compiles only into the app targets (Wikipedia, Experimental and Staging), and none of them exports it. |
| wikipedia-ios-6 | `WMF Framework/Widget/Models/WidgetTopRead.swift:83` | function.constructor `init(dateString:elements:)` | unused | TP | No call site exists in the checkout, including the Widgets extension and WikipediaUnitTests. Instances come only from `init(from:)` via JSONDecoder (WidgetFeaturedContent.swift:137, WidgetSampleContentTests.swift:118). |
| wikipedia-ios-7 | `WMFData/Sources/WMFData/Data Controllers/Settings/WMFSettingsDataController.swift:89` | function.method.instance `didMigrateAutoSignTalkPageDiscussions()` | unused | FP | Called at WMFAppViewController+Extensions.swift:744. The chain is `migrateAutoSignTalkPageDiscussions` ← `setupWMFDataCoreDataStore` (line 697) ← `migrateIfNecessary` (WMFAppViewController.swift:915) ← `launchApp(in:waitToResumeApp:)` ← SceneDelegate.swift:64. SceneDelegate.swift:64 is in the `#else` branch of `#if TEST` (lines 8-21), which is inactive in the Test configuration the scan built. |
| wikipedia-ios-8 | `Wikipedia/Code/ReadingListsViewController.swift:11` | var.parameter `readingListsViewController` | unused | TP | This is a requirement of the internal `ReadingListsViewControllerDelegate`, which is not `@objc`. Neither conformer uses the sender: SavedViewController.swift:690 calls `configureNavigationBar()`, and AddArticlesToReadingListViewController.swift:214 only sets `isHidden`. Caveat: acting requires changing the requirement, both conformers and the call site at line 273 together. |
| wikipedia-ios-9 | `Wikipedia/Code/SavedViewController.swift:686` | var.parameter `readingListsViewController` | unused | TP | This witness is a `// no-op`. The only other conformer, AddArticlesToReadingListViewController.swift:197, also ignores the sender, and Lethen reports the requirement's parameter (ReadingListsViewController.swift:10:39). Caveat: the parameter can only be removed together with the internal protocol requirement and the call sites at lines 342 and 387. |
| wikipedia-ios-10 | `Wikipedia/Code/PageContentService+UITestAccessibilityConfiguration.swift:9` | var.instance `localizedStrings` | assignOnlyProperty | FP | `Script` is `Encodable`. It is serialized by `PageContentService.getJavascriptFor` through `paramsEncoder.encode` (ActionHandlerScript.swift:62-63) at PageContentService+UITestAccessibilityScript.swift:8. The resulting JSON is read in injected JavaScript as `configuration.localizedStrings` (line 17) and `strings.viewEditHistory` (line 117). |
| wikipedia-ios-11 | `Wikipedia/Code/CollectionViewHeader.swift:53` | var.instance `buttonTitle` | unused | TP | Every `buttonTitle` access in the app belongs to a different type, for example `CollectionViewFooter` (ColumnarCollectionViewController.swift:327) and `InsertMediaSettingsButtonView` (InsertMediaSettingsViewController.swift:178). No .m, XIB or storyboard mentions it, and the property is not `@objc`. |
| wikipedia-ios-12 | `Wikipedia/Code/ProfileCoordinator.swift:35` | var.instance `badgeDelegate` | assignOnlyProperty | TP | It is written at 7 sites (for example SearchViewController.swift:93 and ExploreViewController.swift:90) but never read: there is no `badgeDelegate?.` or `badgeDelegate.` anywhere in the checkout. The property is not `@objc`, and no Objective-C or KVC string references it. |
| wikipedia-ios-13 | `Wikipedia/Code/NotificationsCenterCommonViewModel+ActionExtensions.swift:91` | var.parameter `normalizedTitle` | unused | TP | This private function (lines 91-111) never reads `normalizedTitle`; only its sibling `titleText` (line 124) does. The only caller is line 63. |
| wikipedia-ios-14 | `Wikipedia/Code/WMFAppViewController.swift:819` | function.method.instance `endRemoteConfigCheckBackgroundTask()` | unused | FP | Called at lines 1797 and 1804 inside `checkRemoteAppConfigIfNecessary()`. That function is reached from `migrateIfNecessary` (line 923) and `launchApp` (SceneDelegate.swift:64), which exist only in the non-TEST `#else` branch of SceneDelegate.swift. The scan built the Test configuration (`-DTEST`), so this whole launch path was compiled out. |
| wikipedia-ios-15 | `WikipediaUnitTests/Code/DataStoreTests.swift:2` | module `Wikipedia` | unused | TP | The test uses only `MWKDataStore` (WMF, MWKDataStore.h), `createTemporaryDataStore` (Objective-C category in the test target, MWKDataStore+TemporaryDataStore.m:9), and `viewContext.defaultReadingList` (WMF, ReadingListsController.swift:808, reachable via `@testable import WMF`). Nothing comes from the app module. |
| wikipedia-ios-16 | `Wikipedia/Code/WatchlistFunnel.swift:87` | var.instance `errorReason` | assignOnlyProperty | FP | `ActionData` is `Codable` with a `CodingKeys` case `error_reason` (line 92) and is embedded in `Event: EventInterface` (line 165). `EventPlatformClient.submit` serializes the event with `JSONEncoder().encode` (EventPlatformClient.swift:705-712), so the synthesized `encode(to:)` reads the value and sends it to analytics. |
| wikipedia-ios-17 | `Wikipedia/Code/ExploreViewController.swift:1996` | function.method.instance `updateYIRBadgeVisibility()` | unused | TP | `YearInReviewBadgeDelegate.updateYIRBadgeVisibility` (WMFComponents YearInReviewBadgeDelegate.swift:4) is never invoked. There is no call and no selector string in Swift, .m/.h or resources, and the only delegate holders (ProfileCoordinator.swift:35, YearInReviewCoordinator.swift:16) never read their `badgeDelegate`. Lethen reports the requirement and all 7 witnesses consistently. |
| wikipedia-ios-18 | `Wikipedia/Code/WMFPasswordResetter.swift:24` | class `WMFPasswordResetter` | redundantPublicAccessibility | TP | The class is used only at WMFForgotPasswordViewController.swift:19, in the same app module. The file is compiled only into the app targets (Wikipedia, Experimental and Staging), and no other module or Objective-C code references it. |
| wikipedia-ios-19 | `Wikipedia/Code/YearInReviewCoordinator.swift:157` | function.method.instance `logYearInReviewIntroDidTapLearnMore()` | unused | TP | This witnesses `WMFYearInReviewLoggingDelegate.logYearInReviewIntroDidTapLearnMore` (YearInReviewLoggingDelegate.swift:4), which is not `@objc` and is never called anywhere. The only other occurrence is an empty mock in WMFComponentsTests (not built by the scheme). |
| wikipedia-ios-20 | `Wikipedia/Code/ReadingListEntryCollectionViewController.swift:570` | var.parameter `saved` | unused | TP | This conforms to the internal, non-`@objc` `SavedViewControllerDelegate` (SavedViewController.swift:13). Neither conformer uses `saved` (here, and ReadingListsViewController.swift:575), and Lethen reports the requirement and all witnesses. Caveat: the parameter can only be removed together with the requirement and the call at SavedViewController.swift:676. |
| wikipedia-ios-21 | `Wikipedia/Code/DiffListContextViewModel.swift:204` | var.parameter `contextItemPadding` | unused | TP | This private static function (lines 204-217) never reads `contextItemPadding`, unlike `calculateExpandedHeight` (line 183). All callers are in the same file (lines 100, 164, 179 and 224). |
| wikipedia-ios-22 | `WMFData/Sources/WMFData/Data Controllers/Year In Review/Slide Data Controllers/WMFYearInReviewMostReadCategoriesSlideDataController.swift:13` | var.instance `mostReadCategories` | unused | TP | The property is read only in `makeCDSlide` (line 58). That method and every protocol requirement are reported dead because `YearInReviewSlideDataControllerFactory` (WMFYearInReviewSlideDataControllerFactory.swift:4) is never instantiated anywhere. Caveat: this is transitively dead code, and WMFDataTests (YearInReviewSlidePopulateTests.swift:187) exercise it but are not in the scheme's test plan. |
| wikipedia-ios-23 | `WMF Framework/ArticleSummary.swift:26` | var.instance `revision` | assignOnlyProperty | TP | The value is set by decoding and by the internal init (line 76), but nothing reads `ArticleSummary.revision`. The only `.revision` read is a WMFDataTests assertion on a different type. The property is not `@objc`, and `ArticleSummary` is never encoded. Caveat: the `CodingKeys.revision` case (line 42) and the init parameter must be removed with it. |
| wikipedia-ios-24 | `Wikipedia/Code/SavedAllArticlesCoordinator.swift:523` | var.parameter `languageVariantCode` | unused | TP | This private `fetchArticle` builds its predicate from `databaseKey` only (lines 524-527), so `languageVariantCode` is ignored. |
| wikipedia-ios-25 | `WMF Framework/Theme.swift:43` | var.static `wmf_blue_300` | unused | FP | This `@objc static` property is called from Objective-C as `[UIColor wmf_blue_300]` at WMFSettingsMenuItem.m:55, 75 and 117. That file is compiled into the Wikipedia, Experimental and Staging targets. |
| wikipedia-ios-26 | `WMFComponents/Sources/WMFComponents/Components/Activity Tab/WMFTopViewedEditsView.swift:7` | var.instance `appEnvironment` | unused | TP | It is read only by `theme` (line 9), which is itself unused (reported at 8:9); `body` (lines 20-47) never uses theme. Caveat: `@ObservedObject` also subscribes the view to theme changes, but the children that render themed content observe `WMFAppEnvironment.current` themselves (WMFActivityTabInfoCardView, WMFAsyncPageRow). |
| wikipedia-ios-27 | `WMFData/Sources/WMFData/Models/GlobalUserInfo/GlobalUserInfoResponse.swift:17` | var.instance `name` | assignOnlyProperty | TP | `GlobalUserInfo` is decode-only. Its only consumer reads `editcount` (WMFActivityTabDataController.swift:456), and nothing reads `.name`. Caveat: removing this non-optional field makes decoding slightly more lenient. |
| wikipedia-ios-28 | `WMF Framework/Widget/Models/WidgetOnThisDayElement.swift:40` | var.instance `extractHTML` | assignOnlyProperty | TP | Nothing in the app, the WMF framework or the Widgets extension reads `Page.extractHTML`. The other `extractHTML` reads belong to `WidgetTopRead` and `ArticleSummary`. Caveat: the value round-trips through the widget's JSON SharedContainerCache via synthesized `Encodable`, but no consumer reads it back. |
| wikipedia-ios-29 | `Wikipedia/Code/DonateFunnel.swift:565` | var.parameter `slideLoggingID` | unused | TP | The body logs only `metricsID` (line 566). The method is not `@objc` and not a protocol witness, and its only caller is DonateCoordinator.swift:377. |
| wikipedia-ios-30 | `WMF Framework/CacheGroup+CoreDataProperties.swift:27` | function.method.instance `addToCacheItems(_:)` | unused | TP | This is the Xcode-generated `NSSet` overload (`@objc(addCacheItems:)`). Every call site passes a single `CacheItem` and resolves to the line-21 overload (ImageCacheDBWriter.swift:155, ArticleCacheResourceDBWriting.swift:103, ArticleCacheDBWriter+SyncResources.swift:238, ArticleTestHelpers.swift:159), and no Objective-C code sends `addCacheItems:`. Caveat: this is regenerable Core Data boilerplate. |

TP rows worth knowing about: Alamofire-8 and Alamofire-10 are `disabled_test…` methods kept on
purpose; Alamofire-14 is read only by the unused helper Alamofire-13; Alamofire-18 and
Alamofire-22 are parameters of a public method that no longer matches the `EventMonitor`
requirement it was written for, so the whole method is dead but `--retain-public` keeps it;
swift-nio-9, 12, 26 and 30 are test helpers' `file:`/`line:` parameters that are never read;
swift-nio-19 is dead on every platform, but removing it also requires removing the `ThreadOps`
requirement (`Sources/NIOPosix/Thread.swift:39`), which Lethen does not report. wikipedia-ios-4, 8, 9 and 20 are
parameters that neither the app's own (non-`@objc`) protocol requirement nor any conformer reads, so
they are removable only as one change across the protocol, its conformers, and its callers;
wikipedia-ios-22 is read only by a factory that is never created; wikipedia-ios-30 is an Xcode-generated
Core Data accessor that code generation would recreate.

### False-positive classes

| Class | Rows | Fix |
| --- | --- | --- |
| Unused parameters of retained public API: metatype parameters that select a generic type (`_ type: T.Type = T.self`), parameters of public protocol requirements and their witnesses, and witnesses of an external protocol's requirement | Alamofire-1, 12, 16, 26, 28; swift-nio-1, 6, 27, 28 | Under `--retain-public`, keep the parameters of retained public functions and of witnesses to public requirements (new) |
| Properties read by synthesized `Encodable` conformance, and a type used only through one | Alamofire-15, 19, 20, 23; wikipedia-ios-10, 16 | Synthesized `Codable` reads by value flow (Task 9) |
| Code compiled out of the scanned build: Xcode scans run `build-for-testing` with the scheme's Test configuration, whose `TEST` flag hides the app's launch path under `#if TEST … #else`, and `#if DEBUG` blocks; an import used only inside an inactive `#if` | wikipedia-ios-2, 7, 14 | Scan the configuration the app ships, or the union of configurations (new; Task 10 covers SwiftPM only) |
| `@objc` member called only from Objective-C | wikipedia-ios-25 | Reported as `likely` by the confidence tiers; retained with `--retain-objc-accessible` |
| Write-only property that keeps an object alive, or is read by `Mirror` when an error is printed | Alamofire-5; swift-nio-21 | Judgment: lower confidence rather than retain (new) |
| Parameters of a function passed by name as a value, whose signature a function type fixes | swift-nio-22 | Keep parameters of functions referenced without a call (new) |
| Parameter that exists only to bind a constrained generic (`func blackhole<S: Sendable>(_: S) {}`) | swift-nio-20 | Keep a parameter whose type is the only use of a constrained generic parameter (new) |
| Declaration used only under an inactive `#if compiler(...)` branch | swift-nio-25 | Not visible to one build; `--configurations` (Task 10) covers debug/release only |

## Corpus diffs by change

Each analysis pull request appends a section: PR, projects re-scanned, rows added or removed, and
the verdict for every changed row.

### Result builder methods by base name

Alamofire, swift-nio, and Wikipedia iOS re-scanned: no rows added or removed. None of the three
declares a result builder with `buildPartialBlock` or a multi-argument `buildBlock`; the fixture
`testRetainsResultBuilderPartialBlockAndArity` covers the change.
### Property wrapper initializers

Alamofire, swift-nio, and Wikipedia iOS re-scanned: no rows added or removed. No property wrapper
in the three declares an `init(wrappedValue:…)` with further labels or an `init(projectedValue:)`
that was reported; the fixture `testRetainsPropertyWrapperInitializers` covers the change.
### Info.plist document classes

Alamofire, swift-nio, and Wikipedia iOS re-scanned: no rows added or removed. None of them is a
document-based app; `InfoPlistParserTest` covers `NSDocumentClass` inside `CFBundleDocumentTypes`.
### Synthesized Encodable reads by value flow

Alamofire: 11 rows removed, none added. All 11 are properties of structs a test passes to an
encoder (`EncodableStruct`, `NestedEncodableStruct`, `OptionalEncodableStruct` in
`ParameterEncoderTests.swift`, `TestParameters` in `TestHelpers.swift`): fixed false positives,
including sampled rows Alamofire-15, 19, 20 and 23.

swift-nio: no change.

Wikipedia iOS: 261 rows removed (256 assign-only properties, 5 unused types or properties), 2 added.

- A first version treated any call to an unindexed function as possible encoding and removed 317
  rows. A seeded sample of 30 of those found 24 fixed false positives and 6 true positives it hid:
  the values reached `Array.append`, `CheckedContinuation.resume(returning:)`, a synthesized
  memberwise initializer, `??`, or a `nil` assignment, none of which encodes. The rule was narrowed
  to callees whose parameter is constrained to `Encodable` or is `any Encodable` (read from the
  mangled USR for unindexed callees), and a used-but-not-encoded control (`Array.append`, `print`)
  was added to the fixture.
- With the narrowed rule, all 6 hidden true positives are reported again and all 24 fixed false
  positives stay fixed. The values reach `EventPlatformClient.submit<E: EventInterface>` (every
  analytics funnel), `PageContentService.getJavascriptFor<T: Encodable>`,
  `SharedContainerCache.saveCache<T: Codable>`, `WMFKeyValueStore.save<T: Codable>`, or
  `JSONEncoder`/`PropertyListEncoder` directly; they include sampled rows wikipedia-ios-10 and 16.
- The 2 added rows are TP: `WMFOnThisDayContentURLs.init(desktop:mobile:)` and
  `WMFOnThisDayURLPair.init(page:)` have no callers. Their types were previously reported whole
  and are now used, so their dead initializers are reported on their own.

### `--configurations` for SwiftPM

Alamofire, swift-nio, and Wikipedia iOS re-scanned: no rows added or removed. The corpus does not
pass the new flag, and without it a scan builds exactly as before. `SPMConfigurationsTest` covers
the flag on a package with a function called only under `#if DEBUG` and one called only without it.
### Implicit declarations retained through their parent

Alamofire and swift-nio: no change. Wikipedia iOS: 24 rows removed, 5 added.

- The 5 added rows are types now reported whole: `SearchEntry` and `LockscreenSearchEntry`
  (widgets), `SessionsFunnel.SessionData`, and `UserHistoryFunnel` with its extension. Before, each
  was kept alive by a compiler-generated memberwise initializer retained as its own root (for
  example `SearchWidgetView.init(entry:)` referencing `SearchEntry`), even though nothing called
  that initializer. The 24 removed rows are members of those types, which the type-level findings
  now cover.
- All 5 are FP of the "code compiled out of the scanned build" class: `SearchWidget` and
  `LockscreenSearchWidget` are listed in the widget bundle only under `#if DEBUG`, and
  `SessionsFunnel.appDidBecomeActive()` and `UserHistoryFunnel.shared.logSnapshot()` are called
  only from `WMFAppViewController`'s launch path, which the Test configuration compiles out. The
  change removed a false keep-alive that happened to hide them; scanning the configuration the app
  ships is what fixes them.
- No added row is a genuine use through generated code, so no retention pattern needed a fixture.

### `--retain-public-targets` and the build-boundary warning

Alamofire, swift-nio, and Wikipedia iOS re-scanned: no rows added or removed. The two libraries scan
with `--retain-public`, which already retains every public declaration, and the Wikipedia scan lists
no targets. `RetainPublicTargetsTest` covers retention of one listed module with a reported control
in another, and `BuildBoundaryWarningTest` covers the warning.
