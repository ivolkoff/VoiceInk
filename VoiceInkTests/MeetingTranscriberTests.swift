import Foundation
import Testing
@testable import VoiceInk

struct MeetingTranscriberTests {
    @Test func retriesOnlyTransientCloudErrors() {
        #expect(MeetingTranscriber.isRetryable(CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: "")))
        #expect(MeetingTranscriber.isRetryable(CloudTranscriptionError.apiRequestFailed(statusCode: 503, message: "")))
        #expect(MeetingTranscriber.isRetryable(CloudTranscriptionError.networkError(URLError(.timedOut))))
        #expect(!MeetingTranscriber.isRetryable(CloudTranscriptionError.apiRequestFailed(statusCode: 401, message: "")))
        #expect(!MeetingTranscriber.isRetryable(CloudTranscriptionError.streamingOnlyProvider))
        #expect(!MeetingTranscriber.isRetryable(CancellationError()))
    }
}
