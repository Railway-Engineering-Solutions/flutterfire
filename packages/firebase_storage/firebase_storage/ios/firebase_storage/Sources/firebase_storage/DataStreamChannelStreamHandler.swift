// Copyright 2025 The Chromium Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class DataStreamChannelStreamHandler: NSObject, FlutterStreamHandler {
  private let downloadUrl: String
  private let maxSize: Int64
  private var task: URLSessionDataTask?
  private var isCancelled = false

  init(downloadUrl: String, maxSize: Int64) {
    self.downloadUrl = downloadUrl
    self.maxSize = maxSize
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    isCancelled = false
    guard let url = URL(string: downloadUrl) else {
      events([
        "error": [
          "code": "invalid-argument",
          "message": "Invalid download URL",
        ],
      ])
      return nil
    }

    let session = URLSession.shared
    task = session.dataTask(with: url) { [weak self] data, response, error in
      guard let self = self, !self.isCancelled else { return }

      if let error = error {
        events([
          "error": [
            "code": "unknown",
            "message": error.localizedDescription,
          ],
        ])
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        events([
          "error": [
            "code": "unknown",
            "message": "Invalid response type",
          ],
        ])
        return
      }

      if httpResponse.statusCode != 200 {
        events([
          "error": [
            "code": "unknown",
            "message": "Failed to download file: HTTP \(httpResponse.statusCode)",
          ],
        ])
        return
      }

      guard let data = data else {
        events([
          "error": [
            "code": "unknown",
            "message": "No data received",
          ],
        ])
        return
      }

      // Stream data in chunks
      let chunkSize = 8192  // 8KB chunks
      var totalBytesRead: Int64 = 0
      var offset = 0

      while offset < data.count && !self.isCancelled {
        let remainingBytes = data.count - offset
        let currentChunkSize = min(chunkSize, remainingBytes)
        let chunk = data.subdata(in: offset..<(offset + currentChunkSize))

        totalBytesRead += Int64(currentChunkSize)
        if self.maxSize > 0 && totalBytesRead > self.maxSize {
          events([
            "error": [
              "code": "download-size-exceeded",
              "message":
                "Downloaded data exceeds maximum allowed size of \(self.maxSize) bytes",
            ],
          ])
          return
        }

        events(["data": FlutterStandardTypedData(bytes: chunk)])
        offset += currentChunkSize
      }

      if !self.isCancelled {
        events(["complete": true])
      }
    }

    task?.resume()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    isCancelled = true
    task?.cancel()
    task = nil
    return nil
  }
}

