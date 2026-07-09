//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_spi(Testing) import LanguageServerProtocolTransport
import Synchronization
import ToolsProtocolsTestSupport
import XCTest

import struct Foundation.Data
import class Foundation.Pipe

final class PipeForwardingTests: XCTestCase {
  /// `readInBackground` forwards everything written to the pipe and signals end-of-file once the write end
  /// is closed.
  func testReadInBackgroundForwardsAllDataAndSignalsEndOfFile() async throws {
    let pipe = Pipe()
    let received = Mutex<Data>(Data())
    let reachedEndOfFile = expectation(description: "reached end of file")

    JSONRPCConnection.readInBackground(
      fileHandle: pipe.fileHandleForReading,
      queueLabel: "test-read-in-background"
    ) { data in
      received.withLock { $0.append(data) }
    } reachedEndOfFile: {
      reachedEndOfFile.fulfill()
    }

    try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
    try pipe.fileHandleForWriting.write(contentsOf: Data(" world".utf8))
    try pipe.fileHandleForWriting.close()

    try await fulfillmentOfOrThrow(reachedEndOfFile)
    XCTAssertEqual(received.withLock { $0 }, Data("hello world".utf8))
  }

  /// `readInBackground` delivers data as soon as it is available, before the pipe reaches end-of-file. A
  /// read that accumulated until its buffer filled or EOF (as `FileHandle.read(upToCount:)` does on
  /// non-Darwin platforms) would withhold this small chunk until the write end is closed.
  func testReadInBackgroundDeliversDataBeforeEndOfFile() async throws {
    let pipe = Pipe()
    let received = Mutex<Data>(Data())
    let receivedChunk = expectation(description: "received chunk before EOF")
    receivedChunk.assertForOverFulfill = false

    JSONRPCConnection.readInBackground(
      fileHandle: pipe.fileHandleForReading,
      queueLabel: "test-read-in-background-prompt"
    ) { data in
      let total = received.withLock {
        $0.append(data); return $0
      }
      if total == Data("ping".utf8) {
        receivedChunk.fulfill()
      }
    }

    // Do not close the write end: the chunk must be delivered without relying on EOF.
    try pipe.fileHandleForWriting.write(contentsOf: Data("ping".utf8))
    try await fulfillmentOfOrThrow(receivedChunk)

    // Let the read loop terminate so its background thread does not outlive the test.
    try pipe.fileHandleForWriting.close()
  }
}
